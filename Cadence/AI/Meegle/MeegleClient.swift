import Foundation

/// Reads Meegle work items by driving the user's own `meegle` CLI.
///
/// Shelling out rather than speaking the HTTP API keeps Cadence out of the
/// credential business entirely. `meegle auth login` performs a user OAuth flow
/// and leaves the token in the OS keychain, so every call runs **as that user,
/// with exactly their own visibility** — Cadence never holds a token, and there
/// is no app registration for anyone else to authorise. The alternative, plugin
/// credentials, would mean an app identity whose data scope is granted by an
/// administrator and shared by everyone using it.
///
/// Blocking on purpose. `ToolCatalog.call` is synchronous all the way up to the
/// socket, and making that chain async to accommodate one tool would be a large
/// change for no gain: the model is waiting for the answer regardless. What the
/// blocking does demand is the timeout below, since a wedged CLI would
/// otherwise wedge the connection's queue with it.
final class MeegleClient: @unchecked Sendable {

    /// Pages are 50 items and the response carries no `has_more`, so the only
    /// way to know you have reached the end is an empty page. This caps how
    /// long that walk can go on.
    static let maxPages = 20
    static let defaultTimeoutSeconds = 30

    private let invocation: CLIInvocation
    private let timeoutSeconds: Int
    /// Injected in tests so the parsing and paging can be exercised without a
    /// login, a network, or the CLI being installed.
    private let execute: (@Sendable ([String]) throws -> Data)?

    /// Fails when `meegle` is not on the user's path — including the paths that
    /// only exist inside their shell's rc files, which `CLILocator` handles.
    init(timeoutSeconds: Int = MeegleClient.defaultTimeoutSeconds) throws {
        guard let invocation = try? CLILocator.invocation(for: "meegle") else {
            throw MeegleError.notInstalled
        }
        self.invocation = invocation
        self.timeoutSeconds = timeoutSeconds
        self.execute = nil
    }

    init(execute: @escaping @Sendable ([String]) throws -> Data) {
        self.invocation = .executable(URL(fileURLWithPath: "/usr/bin/false"))
        self.timeoutSeconds = MeegleClient.defaultTimeoutSeconds
        self.execute = execute
    }

    /// The client the tool catalog is built with, or nil when the user has not
    /// switched the connector on or the CLI is not installed. One decision in
    /// one place, so the three places a catalog is constructed cannot disagree
    /// about whether Meegle is available.
    @MainActor
    static func configured() -> MeegleClient? {
        guard Preferences.shared.meegleEnabled else { return nil }
        return try? MeegleClient()
    }

    // MARK: - Reads

    /// Every work item in one of the four lists, following pages to the end.
    func workItems(action: MeegleAction) throws -> [MeegleWorkItem] {
        var collected: [MeegleWorkItem] = []
        var seen = Set<String>()

        for page in 1...Self.maxPages {
            let data = try run([
                "mywork", "todo",
                "--action", action.rawValue,
                "--page-num", String(page),
                "--format", "json"
            ])
            let items = try MeegleParser.workItems(from: data)
            if items.isEmpty { break }
            // Defensive rather than observed: a shifting page boundary would
            // otherwise turn one work item into two tasks.
            collected.append(contentsOf: items.filter { seen.insert($0.id).inserted })
            if items.count < 50 { break }
        }
        return collected
    }

    /// Whether the user is logged in, and to which host. Cheap enough to call
    /// before every read, which is what keeps the error message accurate when
    /// a token quietly expires — they are short-lived.
    func isAuthenticated() -> Bool {
        guard let data = try? run(["auth", "status", "--format", "json"]),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return root["authenticated"] as? Bool ?? false
    }

    // MARK: - Process

    private func run(_ arguments: [String]) throws -> Data {
        if let execute { return try execute(arguments) }

        let process = Process()
        switch invocation {
        case .executable(let url):
            process.executableURL = url
            process.arguments = arguments

        case .loginShell(let command, let shell):
            // Same treatment the AI CLI gets: the command bare so an alias
            // still expands, every argument quoted, the whole line under `eval`
            // because zsh parses `-c` before the rc files have defined
            // anything. See AI-INTEGRATION.md §7.
            let line = ([command] + arguments.map(CLILocator.shellQuoted))
                .joined(separator: " ")
            process.executableURL = shell
            process.arguments = ["-ilc", "eval \(CLILocator.shellQuoted(line))"]
        }

        // A GUI app's environment has no rc file behind it, so the CLI would
        // not find its own node runtime.
        var environment = ProcessInfo.processInfo.environment
            .merging(LoginEnvironment.variables) { _, fromShell in fromShell }
        var seen = Set<String>()
        environment["PATH"] = (LoginEnvironment.searchPaths
            + (environment["PATH"]?.split(separator: ":").map(String.init) ?? [])
            + CLILocator.searchPaths)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do { try process.run() } catch {
            throw MeegleError.failed(error.localizedDescription)
        }

        // Both pipes are drained on their own queues *before* waiting. Reading
        // after `waitUntilExit` deadlocks as soon as the output outgrows the
        // pipe buffer, and a full page of work items comfortably does.
        let out = DataCollector()
        let err = DataCollector()
        let group = DispatchGroup()
        for (pipe, sink) in [(outPipe, out), (errPipe, err)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                sink.append(pipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
        }

        let timedOut = Flag()
        let watchdog = DispatchWorkItem { [weak process] in
            timedOut.set()
            process?.terminate()
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .seconds(timeoutSeconds), execute: watchdog
        )

        process.waitUntilExit()
        group.wait()
        watchdog.cancel()

        if timedOut.value { throw MeegleError.timedOut(seconds: timeoutSeconds) }

        guard process.terminationStatus == 0 else {
            let message = String(data: err.data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // The CLI reports this on stderr in prose; turning it into the
            // typed case is what lets the tool tell the model to say "log in"
            // rather than surfacing a raw failure.
            if message.localizedCaseInsensitiveContains("auth")
                || message.localizedCaseInsensitiveContains("login") {
                throw MeegleError.notAuthenticated
            }
            throw MeegleError.failed(message.isEmpty ? "exit \(process.terminationStatus)" : message)
        }
        return out.data
    }
}

private final class DataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ chunk: Data) { lock.lock(); storage.append(chunk); lock.unlock() }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool { lock.lock(); defer { lock.unlock() }; return storage }
    func set() { lock.lock(); storage = true; lock.unlock() }
}
