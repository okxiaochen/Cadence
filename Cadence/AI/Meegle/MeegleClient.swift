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

    private let process: CLIProcess?
    /// Injected in tests so the parsing and paging can be exercised without a
    /// login, a network, or the CLI being installed.
    private let execute: (@Sendable ([String]) throws -> Data)?

    /// Fails when `meegle` is not on the user's path — including the paths that
    /// only exist inside their shell's rc files, which `CLILocator` handles.
    init(timeoutSeconds: Int = MeegleClient.defaultTimeoutSeconds) throws {
        do {
            self.process = try CLIProcess(command: "meegle", timeoutSeconds: timeoutSeconds)
        } catch {
            throw MeegleError.notInstalled
        }
        self.execute = nil
    }

    init(execute: @escaping @Sendable ([String]) throws -> Data) {
        self.process = nil
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
        guard let process else { throw MeegleError.notInstalled }
        do {
            return try process.run(arguments, named: "meegle")
        } catch let failure as CLIProcess.Failure {
            throw Self.translate(failure)
        }
    }

    /// The CLI reports "not logged in" on stderr in prose. Turning it into the
    /// typed case is what lets the tool tell the model to say "log in" rather
    /// than surfacing a raw failure the user cannot act on.
    private static func translate(_ failure: CLIProcess.Failure) -> MeegleError {
        switch failure {
        case .notInstalled: return .notInstalled
        case .timedOut(_, let seconds): return .timedOut(seconds: seconds)
        case .failed(_, let message):
            if message.localizedCaseInsensitiveContains("auth")
                || message.localizedCaseInsensitiveContains("login") {
                return .notAuthenticated
            }
            return .failed(message)
        }
    }
}

