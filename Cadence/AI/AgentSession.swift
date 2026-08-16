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

    /// The thread the panel is showing. Every run is filed against it, so the
    /// panel can be cleared and a past conversation reopened.
    private(set) var conversationID = UUID().uuidString

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

    /// How the configured command resolved, for Settings to report.
    private(set) var resolvedInvocation: CLIInvocation?

    func checkConfiguration() {
        do {
            resolvedInvocation = try CLILocator.invocation(for: configuration.command)
            configurationProblem = nil
        } catch {
            resolvedInvocation = nil
            configurationProblem = error.localizedDescription
        }
    }

    /// Runs a trivial prompt to prove the whole path works end to end.
    func testConnection() async -> String {
        do {
            let invocation = try CLILocator.invocation(for: configuration.command)
            let started = Date()
            let result = try await runner.run(
                invocation: invocation,
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

        // Captured before this turn is appended, so the model is told what came
        // *before* rather than being handed the question twice.
        let history = transcriptForPrompt()
        messages.append(ChatMessage(role: .user, text: trimmed))
        // Synchronously, so the button disables and the spinner appears on the
        // click rather than a run-loop tick later.
        status = .running
        task = Task { await run(prompt: trimmed, surface: surface, history: history) }
    }

    func cancel() {
        runner.terminate()
        task?.cancel()
        task = nil
        server.stop()
        status = .idle
    }

    // MARK: - Conversations

    /// Clears the panel and starts a fresh thread. The old one is not lost —
    /// every turn was filed against its conversation and can be reopened.
    func startNewConversation() {
        guard !status.isRunning else { return }
        conversationID = UUID().uuidString
        messages = []
        proposal = nil
        toolCalls = []
        rawOutput = ""
        commandLine = ""
    }

    var isEmptyConversation: Bool { messages.isEmpty }

    func conversations() -> [AIConversation] {
        (try? model.database.writer.read { db in
            try AIRunRepository.conversations(db)
        }) ?? []
    }

    /// Reopens a past thread: its turns become the transcript again, and
    /// anything sent next continues it.
    func open(_ conversation: AIConversation) {
        guard !status.isRunning else { return }
        let runs = (try? model.database.writer.read { db in
            try AIRunRepository.runs(db, conversationID: conversation.id)
        }) ?? []

        conversationID = conversation.id
        proposal = nil
        messages = runs.flatMap { run -> [ChatMessage] in
            var turn = [ChatMessage(role: .user, text: run.prompt)]
            let reply = Self.parseFinalText(from: run.rawOutput)
            if !reply.isEmpty {
                turn.append(ChatMessage(role: .assistant, text: reply))
            } else if run.statusValue == .failed {
                turn.append(ChatMessage(role: .system, text: "That run failed.", isError: true))
            }
            return turn
        }
    }

    func deleteConversation(_ conversation: AIConversation) {
        try? model.database.writer.write { db in
            try AIRunRepository.deleteConversation(db, id: conversation.id)
        }
        if conversation.id == conversationID { startNewConversation() }
    }

    /// The last few turns, for the CLI.
    ///
    /// Each run is a fresh process with no memory of the last one, so without
    /// this the panel only looked like a conversation: "make it 30 minutes
    /// instead" reached a model that had never heard of *it*. Capped at three
    /// exchanges and trimmed, because this is prepended to every prompt and a
    /// long thread would push out the request itself.
    private func transcriptForPrompt(maxTurns: Int = 6, maxCharacters: Int = 400) -> String {
        let recent = messages
            .filter { $0.role != .system && !$0.isError }
            .suffix(maxTurns)
        guard !recent.isEmpty else { return "" }

        return recent
            .map { message in
                let who = message.role == .user ? "User" : "You"
                let text = message.text.count > maxCharacters
                    ? String(message.text.prefix(maxCharacters)) + "…"
                    : message.text
                return "\(who): \(text)"
            }
            .joined(separator: "\n")
    }

    private func run(prompt: String, surface: AISurface, history: String = "") async {
        status = .running
        toolCalls = []
        rawOutput = ""
        proposal = nil

        let buffer = ProposalBuffer()
        var run = AIRun(surface: surface.rawValue, prompt: prompt, command: "")
        run.conversationID = conversationID

        do {
            let invocation = try CLILocator.invocation(for: configuration.command)

            let catalog = ToolCatalog(
                database: model.database,
                buffer: buffer,
                context: model.planningContext(),
                meegle: MeegleClient.configured()
            )
            server.onToolCall = { [weak self] name in
                Task { @MainActor in self?.toolCalls.append(name) }
            }
            try server.start(catalog: catalog)
            defer { server.stop() }

            let configURL = try writeMCPConfig()
            defer { try? FileManager.default.removeItem(at: configURL) }

            let arguments = buildArguments(
                prompt: prompt,
                surface: surface,
                configURL: configURL,
                history: history
            )
            run.command = ([invocation.displayPath] + arguments).joined(separator: " ")
            commandLine = run.command
            persist(run)

            let result = try await runner.run(
                invocation: invocation,
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
            let text = Self.parseFinalText(from: result.stdout)

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

    private func buildArguments(
        prompt: String,
        surface: AISurface,
        configURL: URL,
        history: String = ""
    ) -> [String] {
        var arguments = configuration.arguments
        let system = systemPrompt(for: surface, history: history)

        if configuration.transport == .mcp, !configuration.mcpArguments.isEmpty {
            arguments += configuration.mcpArguments.map { argument in
                argument
                    .replacingOccurrences(of: "{config}", with: configURL.path)
                    .replacingOccurrences(
                        of: "{tools}", with: allowedTools.joined(separator: ",")
                    )
            }
        }

        // A CLI with no flag for a system prompt gets it in the prompt itself.
        // Every CLI takes a prompt; not every one takes that flag, and the
        // rules the assistant follows are compiled into that text — dropping it
        // would leave the model with tools and no idea what it may do with them.
        if configuration.systemPromptArguments.isEmpty {
            arguments.append(Self.prependingSystemPrompt(system, to: prompt))
        } else {
            arguments += configuration.systemPromptArguments.map {
                $0.replacingOccurrences(of: "{system}", with: system)
            }
            arguments.append(prompt)
        }
        return arguments
    }

    /// The separator matters: without a visible break the model reads the rules
    /// as part of the request and answers them.
    static func prependingSystemPrompt(_ system: String, to prompt: String) -> String {
        """
        \(system)

        ---

        \(prompt)
        """
    }

    private var allowedTools: [String] {
        ToolCatalog(
            database: model.database,
            buffer: ProposalBuffer(),
            context: model.planningContext(),
            meegle: MeegleClient.configured()
        )
        .tools()
        .map { "mcp__cadence__\($0.name)" }
    }

    /// Internal rather than private so it can be asserted on: this is the whole
    /// of what the assistant is told, and it ships to every user.
    func systemPrompt(for surface: AISurface, history: String = "") -> String {
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
        - A scheduled task's estimate IS the length of its block. Propose a block
          of exactly the estimate, or change the estimate to match. They cannot
          disagree — if you leave them disagreeing, one silently overwrites the
          other and the result is not what you intended.
        - Before you put a number on how long something takes, call
          get_estimate_history. Their own records of what this kind of work
          actually took beat your intuition about it.
        - Stage every task change with a propose_* tool. Nothing you do to their
          tasks is saved directly; the user reviews it first.
        - Call explain last, with a one-paragraph summary and any warnings.
        - Be concise. Do not narrate your tool use.
        \(workItemRules)
        \(Self.externalWorkRules)

        Memory:
        - The notes below are what you already know. Use them when planning.
        - Before you finish, ask yourself whether this turn taught you anything
          durable about how this person works — a preference, a project's shape,
          a goal, a constraint, a habit their records show. If it did, save it
          with `remember`. This is a judgement you make every turn, not a chore
          for later: the fact is cheapest to record the moment it is said.
        - Say nothing about it in your reply unless the user asks. Storing a
          memory is not news.
        - Memory is saved directly, not reviewed, so store facts rather than
          guesses.
        - When something you learn CONTRADICTS a note below, call `remember` with
          that note's existing key to replace it. Do not leave both versions.
          People change their minds; the memory should change with them.
        - Store what a turn *implies*, never the turn itself: "prefers deep work
          before lunch" is durable, "asked me to move the review to Thursday" is
          not. Individual tasks belong in the task list, not in memory.
        - Set `source` honestly, because it decides what gets questioned later.
          "user" means they told you, and never expires — there is nothing to
          re-check it against, so claiming it for a guess buries the guess
          permanently. Use "inferred" for anything you worked out from their
          records, or name the system you read it from. Everything that is not
          "user" comes back for review.
        - A note marked UNVERIFIED below is one nobody has confirmed lately. Use
          it if you must, but check it against what you can see now, and then
          say so: confirm_memory if it holds, remember with the same key if it
          has changed, forget if it is simply over.

        \(surface.instruction)

        \(skillSection)

        \(memorySection)
        \(historySection(history))
        """
    }

    /// Empty unless the Meegle connector is on, matching the tool catalog.
    /// Describing a tool the model has not been given is worse than saying
    /// nothing: it spends the turn trying to call it and reports the failure as
    /// though the user's data were missing.
    private var workItemRules: String {
        Self.workItemRules(enabled: MeegleClient.configured() != nil)
    }

    /// Split from the property so both branches are testable without reaching
    /// through `Preferences.shared`.
    static func workItemRules(enabled: Bool) -> String {
        guard enabled else { return "" }
        return """
        - list_work_items is the connected task platform. Call it with action
          "overdue" before "todo".
        - Check alreadyInCadence, and pass externalID straight through on
          anything you propose creating.
        """
    }

    /// How to think about work that lives somewhere else — which is most of it,
    /// for most people.
    ///
    /// Always present, including when nothing is connected, and that is the
    /// point. A model that believes Cadence holds the whole picture reports an
    /// empty evening as a free one, to someone with forty tickets open
    /// elsewhere. Knowing the picture is partial changes what it is honest to
    /// say long before there is a tool to fix it.
    ///
    /// Deliberately about *kinds* of source rather than named platforms. There
    /// are too many — Jira, Asana, Linear, Slack, Notion — and one integration
    /// per platform does not scale. What generalises is the judgement: what a
    /// queue is, what a ticket title is worth, and that whatever is worked out
    /// about a source has to be written down rather than worked out again.
    static let externalWorkRules = """

        Where the work comes from:
        - Cadence holds what this person typed into it. That is rarely all of
          it. Work also arrives as tickets on a task platform, as documents
          those tickets link to, and as messages nobody has dealt with yet.
        - So "nothing scheduled" means nothing is scheduled *here*. It does not
          mean the day is free, and reporting it as though it did is how a
          planner stops being trusted. Say which you mean.
        - You will see tools for the sources that are connected. Where there is
          no tool there is no source: do not guess at what might be in one.

        Reading a source that is connected:
        - Read it before planning a day or a week, not after.
        - What comes back is a queue, not a plan. Judge it before copying any of
          it across: finished items, things already here, and a platform's own
          onboarding content all look like work and are not.
        - A ticket title names a symptom; a task title names an action. "User
          cannot log-in" is a report. "Reproduce the login failure" is a task.
          Write it the way they would have, and keep the original wording in the
          notes rather than the title.
        - Carry the source's own id through, so reading it again revises what is
          here instead of duplicating it.
        - Most external items carry no dates. That is not missing information —
          deciding when they happen is the job.

        Keeping what you work out:
        - When you learn how one of these sources behaves — which call returns
          the open items, what its output actually means, where it misleads —
          write it down with save_skill. A run that has to work it out again has
          spent your time and theirs on something already known once.
        """

    /// Each run is a fresh process, so continuity has to be handed over
    /// explicitly. Labelled as *earlier* turns so the model answers the new
    /// request rather than redoing the last one.
    private func historySection(_ history: String) -> String {
        guard !history.isEmpty else { return "" }
        return """

        Earlier in this conversation (for context — do not redo this work):
        \(history)
        """
    }

    /// One line per skill, never the steps. A procedure is long enough that
    /// loading them all speculatively would cost more than working one out
    /// again; the outline exists so the model knows what it *could* look up.
    private var skillSection: String {
        (try? model.database.writer.read { db in
            try SkillRepository.promptSection(db)
        }) ?? ""
    }

    /// Pinned memories in full plus a one-line outline of the rest, so a growing
    /// memory never crowds out the actual request.
    private var memorySection: String {
        (try? model.database.writer.read { db in
            try MemoryRepository.promptSection(db)
        }) ?? ""
    }

    /// Unwraps whatever envelope the CLI's JSON output mode produced.
    ///
    /// Only Claude Code's `{"result": …}` is verified — neither Gemini nor
    /// Cursor was signed in on the machine this was written on, so their
    /// success shape is inferred from their error output and their flags. The
    /// other keys are therefore guesses, and the fallback is what actually
    /// carries them: an envelope nobody here recognises is returned whole, so
    /// the user sees the model's words wrapped in JSON rather than nothing.
    static func parseFinalText(from stdout: String) -> String {
        let raw = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return raw }

        // An error is worth surfacing as itself; falling through would hand the
        // user a JSON blob to interpret.
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        if let error = object["error"] as? String { return error }

        for key in ["result", "response", "text", "output", "content"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return raw
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
