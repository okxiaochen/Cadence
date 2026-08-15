import Foundation
import Observation

/// Lets other tools — Claude Code, an editor, a script — drive Cadence over MCP.
///
/// The app already speaks MCP: it stands a server up for its own CLI runs, with
/// an ephemeral port and a per-run token. This is the same server and the same
/// tool catalog, kept up for as long as the app is running, on a fixed port
/// with a token that survives relaunches — because a client configured once
/// cannot chase a port that moves.
///
/// **Writes still go through review.** An external agent's `propose_*` calls
/// land in a proposal buffer exactly as the app's own runs do, and surface in
/// the review panel for you to accept or reject. An agent cannot silently
/// rewrite your week; it can only ask. The exceptions are the journal tools
/// (`log_progress`, `log_time`) and memory, which add rather than alter.
///
/// Off by default. It is a socket other processes can talk to, and that is a
/// decision the user makes deliberately rather than one they discover.
@MainActor
@Observable
final class ExternalAgentService {

    static let defaultPort: UInt16 = 8_787

    private let model: AppModel
    private let server = MCPServer()
    private var buffer = ProposalBuffer()
    /// Presenting is debounced: an agent stages several changes in a row, and a
    /// review card that appeared after the first one would be half a plan.
    private var presentTask: Task<Void, Never>?

    private(set) var lastError: String?
    private(set) var lastActivity: Date?

    var isRunning: Bool { server.isRunning }
    var endpoint: String? { server.endpoint }

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Key.enabled)
            if isEnabled { start() } else { stop() }
        }
    }

    var port: UInt16 {
        didSet {
            UserDefaults.standard.set(Int(port), forKey: Key.port)
            if isEnabled { start() }
        }
    }

    init(model: AppModel) {
        self.model = model
        self.isEnabled = UserDefaults.standard.bool(forKey: Key.enabled)
        let stored = UserDefaults.standard.integer(forKey: Key.port)
        self.port = stored > 0 ? UInt16(stored) : Self.defaultPort
    }

    // MARK: - Lifecycle

    func startIfEnabled() {
        guard isEnabled else { return }
        start()
    }

    func start() {
        stop()
        do {
            let catalog = ToolCatalog(
                database: model.database,
                buffer: buffer,
                context: model.planningContext(),
                meegle: MeegleClient.configured()
            )
            server.onToolCall = { [weak self] name in
                Task { @MainActor in self?.noteToolCall(name) }
            }
            try server.start(catalog: catalog, port: port, token: try Self.persistentToken())
            try writeConnectionFile()
            lastError = nil
        } catch {
            lastError = "Could not open port \(port): \(error.localizedDescription)"
            isEnabledWithoutRestarting = false
        }
    }

    func stop() {
        presentTask?.cancel()
        server.stop()
    }

    /// Assigning `isEnabled` would restart the server we just failed to start.
    private var isEnabledWithoutRestarting: Bool {
        get { isEnabled }
        set { UserDefaults.standard.set(newValue, forKey: Key.enabled) }
    }

    // MARK: - Review

    private func noteToolCall(_ name: String) {
        lastActivity = Date()
        guard name.hasPrefix("propose_") || name == "explain" else { return }

        presentTask?.cancel()
        presentTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.presentStagedChanges()
        }
    }

    /// Hands whatever the agent staged to the same review path an in-app run
    /// uses, so an external proposal is reviewed in exactly the same card.
    private func presentStagedChanges() {
        let (changes, summary, warnings) = buffer.drain()
        guard !changes.isEmpty else { return }
        model.presentExternalProposal(changes: changes, summary: summary, warnings: warnings)
    }

    // MARK: - Connection file

    /// Where the token lives, beside the release key rather than in the bundle:
    /// mode 600, outside the repo, and not replaced by an app update.
    static var connectionFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/cadence/mcp.json")
    }

    private static var tokenFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/cadence/mcp-token")
    }

    /// Stable across launches, so a client configured once keeps working.
    static func persistentToken() throws -> String {
        let url = tokenFileURL
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try token.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }

    /// An MCP client config, ready to point a tool at.
    private func writeConnectionFile() throws {
        guard let endpoint = server.endpoint else { return }
        let config: [String: Any] = [
            "mcpServers": [
                "cadence": [
                    "type": "http",
                    "url": endpoint,
                    "headers": ["Authorization": "Bearer \(server.token)"]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
        let url = Self.connectionFileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The one-liner that connects Claude Code to this app.
    var setupCommand: String {
        let endpoint = server.endpoint ?? "http://127.0.0.1:\(port)/mcp"
        let token = (try? Self.persistentToken()) ?? "<token>"
        return "claude mcp add --transport http cadence \(endpoint) "
            + "--header \"Authorization: Bearer \(token)\""
    }

    private enum Key {
        static let enabled = "externalAgentEnabled"
        static let port = "externalAgentPort"
    }
}
