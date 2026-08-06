import Foundation
import Observation

struct ChatMessage: Identifiable, Hashable {
    enum Role { case user, assistant, system }

    var id = UUID()
    var role: Role
    var text: String
    var proposalID: String?
    var isError = false
}

/// Drives one AI run end to end: start the MCP server, invoke the CLI, drain
/// the staged changes, validate them, and hand back a reviewable proposal.
/// Nothing reaches the database until `apply` is called.
@MainActor
@Observable
final class AgentSession {

    enum Status: Equatable {
        case idle, running, failed(String)

        var isRunning: Bool { self == .running }
    }

    private(set) var status: Status = .idle
    private(set) var messages: [ChatMessage] = []
    private(set) var toolCalls: [String] = []
    private(set) var rawOutput = ""
    private(set) var commandLine = ""
    private(set) var proposal: Proposal?

    /// Set when the CLI cannot be found, so the UI can disable AI surfaces.
    private(set) var configurationProblem: String?

    var configuration: CLIConfiguration {
        didSet { configuration.save() }
    }

    private let model: AppModel
    private let server = MCPServer()
    private let runner = CLIRunner()
    private var task: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        self.configuration = CLIConfiguration.load()
        checkConfiguration()
    }

    // MARK: - Configuration

    func checkConfiguration() {
        do {
            _ = try CLILocator.resolve(configuration.command)
            configurationProblem = nil
        } catch {
            configurationProblem = error.localizedDescription
        }
    }

    /// Runs a trivial prompt to prove the whole path works end to end.
    func testConnection() async -> String {
        do {
            let executable = try CLILocator.resolve(configuration.command)
            let started = Date()
            let result = try await runner.run(
                executable: executable,
                arguments: configuration.arguments + ["Reply with the single word: ready"],
                workingDirectory: URL(fileURLWithPath: configuration.workingDirectory),
                timeoutSeconds: min(60, configuration.timeoutSeconds)
            )
            let elapsed = String(format: "%.1fs", Date().timeIntervalSince(started))
            guard result.succeeded else {
                return "Exit code \(result.exitCode): \(result.stderr.prefix(200))"
            }
            return "OK in \(elapsed) — \(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))"
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Running

    func send(_ prompt: String, surface: AISurface = .chat) {
        guard !status.isRunning else { return }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        messages.append(ChatMessage(role: .user, text: trimmed))
        // Synchronously, so the button disables and the spinner appears on the
        // click rather than a run-loop tick later.
        status = .running
        task = Task { await run(prompt: trimmed, surface: surface) }
    }

    func cancel() {
        runner.terminate()
        task?.cancel()
        task = nil
        server.stop()
        status = .idle
    }

    private func run(prompt: String, surface: AISurface) async {
        status = .running
        toolCalls = []
        rawOutput = ""
        proposal = nil

        let buffer = ProposalBuffer()
        var run = AIRun(surface: surface.rawValue, prompt: prompt, command: "")

        do {
            let executable = try CLILocator.resolve(configuration.command)

            let catalog = ToolCatalog(
                database: model.database,
                buffer: buffer,
                context: model.planningContext()
            )
            server.onToolCall = { [weak self] name in
                Task { @MainActor in self?.toolCalls.append(name) }
            }
            try server.start(catalog: catalog)
            defer { server.stop() }

            let configURL = try writeMCPConfig()
            defer { try? FileManager.default.removeItem(at: configURL) }

            let arguments = buildArguments(prompt: prompt, surface: surface, configURL: configURL)
            run.command = ([executable.path] + arguments).joined(separator: " ")
            commandLine = run.command
            persist(run)

            let result = try await runner.run(
                executable: executable,
                arguments: arguments,
                workingDirectory: URL(fileURLWithPath: configuration.workingDirectory),
                timeoutSeconds: configuration.timeoutSeconds,
                onOutput: { [weak self] chunk in
                    Task { @MainActor in self?.rawOutput += chunk }
                }
            )

            run.rawOutput = result.stdout + (result.stderr.isEmpty ? "" : "\n[stderr]\n" + result.stderr)
            run.finishedAt = Date()

            guard result.succeeded else {
                run.status = AIRun.Status.failed.rawValue
                persist(run)
                fail(result.stderr.isEmpty
                     ? "The AI CLI exited with code \(result.exitCode)."
                     : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                return
            }

            let (changes, summary, warnings) = buffer.drain()
            let text = parseFinalText(from: result.stdout)

            if changes.isEmpty {
                messages.append(ChatMessage(
                    role: .assistant,
                    text: summary.isEmpty ? (text.isEmpty ? "Nothing to do." : text) : summary
                ))
            } else {
                let reviewed = model.review(
                    changes,
                    runID: run.id,
                    summary: summary.isEmpty ? text : summary,
                    warnings: warnings
                )
                proposal = reviewed
                messages.append(ChatMessage(
                    role: .assistant,
                    text: reviewed.summary.isEmpty ? "Proposed \(reviewed.changes.count) changes." : reviewed.summary,
                    proposalID: reviewed.id
                ))
            }

            run.status = AIRun.Status.succeeded.rawValue
            persist(run)
            status = .idle

        } catch is CancellationError {
            run.status = AIRun.Status.cancelled.rawValue
            run.finishedAt = Date()
            persist(run)
            status = .idle
        } catch {
            run.status = AIRun.Status.failed.rawValue
            run.finishedAt = Date()
            run.rawOutput = error.localizedDescription
            persist(run)
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        status = .failed(message)
        messages.append(ChatMessage(role: .system, text: message, isError: true))
    }

    // MARK: - Proposal

    func applyProposal() {
        guard let proposal else { return }
        let applied = model.apply(proposal, actionName: label(for: proposal))
        messages.append(ChatMessage(
            role: .system,
            text: applied == 1 ? "Applied 1 change." : "Applied \(applied) changes."
        ))
        self.proposal = nil
    }

    func discardProposal() {
        proposal = nil
        messages.append(ChatMessage(role: .system, text: "Discarded."))
    }

    func setAccepted(_ accepted: Bool, for changeID: String) {
        guard var proposal else { return }
        guard let index = proposal.changes.firstIndex(where: { $0.id == changeID }) else { return }
        proposal.changes[index].isAccepted = accepted
        self.proposal = proposal
    }

    private func label(for proposal: Proposal) -> String {
        proposal.changes.contains { $0.change.isScheduling } ? "AI Schedule" : "AI Changes"
    }

    // MARK: - Invocation

    private func writeMCPConfig() throws -> URL {
        guard let json = server.configurationJSON() else { throw MCPServerError.couldNotBind }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-mcp-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        // The bearer token lives in this file; keep it to the current user.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private func buildArguments(prompt: String, surface: AISurface, configURL: URL) -> [String] {
        var arguments = configuration.arguments

        if configuration.transport == .mcp {
            arguments += [
                "--mcp-config", configURL.path,
                // Ignore the user's other MCP servers so a run is hermetic.
                "--strict-mcp-config",
                "--allowed-tools", allowedTools.joined(separator: ",")
            ]
        }
        arguments += ["--output-format", "json"]
        arguments += ["--append-system-prompt", systemPrompt(for: surface)]
        arguments.append(prompt)
        return arguments
    }

    private var allowedTools: [String] {
        ToolCatalog(
            database: model.database,
            buffer: ProposalBuffer(),
            context: model.planningContext()
        )
        .tools()
        .map { "mcp__cadence__\($0.name)" }
    }

    private func systemPrompt(for surface: AISurface) -> String {
        let context = model.planningContext()
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMMM yyyy"

        return """
        You are the scheduling agent inside Cadence, a personal macOS task manager.

        Today is \(formatter.string(from: now)). The current time is \
        \(Format.time(now)). Timezone \(TimeZone.current.identifier). Working \
        hours are \(context.workdayStartHour):00–\(context.workdayEndHour):00\
        \(context.includesWeekends ? ", weekends included" : ", weekdays only").

        Rules:
        - Use find_free_slots to locate time. NEVER compute availability yourself.
        - Never schedule over busy time unless the user explicitly asks.
        - Respect due dates. If something cannot fit, say so in explain rather
          than forcing it.
        - Stage every task change with a propose_* tool. Nothing you do to their
          tasks is saved directly; the user reviews it first.
        - Call explain last, with a one-paragraph summary and any warnings.
        - Be concise. Do not narrate your tool use.

        Memory:
        - The notes below are what you already know. Use them when planning.
        - When you learn something durable — a preference, a project's shape, a
          goal, a constraint — save it with `remember`. Memory is saved directly,
          not reviewed, so store facts rather than guesses.
        - When something you learn CONTRADICTS a note below, call `remember` with
          that note's existing key to replace it. Do not leave both versions.
          People change their minds; the memory should change with them.
        - Never store individual tasks or what happened in this conversation.

        \(surface.instruction)

        \(memorySection)
        """
    }

    /// Pinned memories in full plus a one-line outline of the rest, so a growing
    /// memory never crowds out the actual request.
    private var memorySection: String {
        (try? model.database.writer.read { db in
            try MemoryRepository.promptSection(db)
        }) ?? ""
    }

    /// `--output-format json` wraps the reply; fall back to the raw text.
    private func parseFinalText(from stdout: String) -> String {
        guard let data = stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let result = object["result"] as? String { return result }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func persist(_ run: AIRun) {
        do {
            try model.database.writer.write { db in
                if try AIRun.fetchOne(db, sql: "SELECT * FROM ai_run WHERE id = ?", arguments: [run.id]) != nil {
                    try AIRunRepository.update(db, run)
                } else {
                    try AIRunRepository.insert(db, run)
                }
            }
        } catch {
            // A failed audit write must never take down the run itself.
            rawOutput += "\n[could not record run: \(error.localizedDescription)]"
        }
    }
}
