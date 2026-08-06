import Foundation
import Network

/// A minimal MCP server over HTTP on the loopback interface.
///
/// The app is already running and owns the database, so the usual stdio
/// transport (where the *client* spawns the server) is the wrong shape. Instead
/// the CLI is handed a config pointing at 127.0.0.1 with a per-run bearer token
/// (AI-INTEGRATION.md §3.1).
///
/// Security: loopback only, token required on every request, token rotated per
/// run, and unexpected `Origin` headers rejected.
final class MCPServer: @unchecked Sendable {

    private(set) var port: UInt16?
    private(set) var token: String = ""

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dev.xiaochen.Cadence.mcp")
    private var catalog: ToolCatalog?
    private let lock = NSLock()

    /// Tool calls as they happen, for the streaming run panel.
    var onToolCall: (@Sendable (String) -> Void)?

    var isRunning: Bool { listener != nil }

    var endpoint: String? {
        guard let port else { return nil }
        return "http://127.0.0.1:\(port)/mcp"
    }

    // MARK: - Lifecycle

    func start(catalog: ToolCatalog) throws {
        stop()

        lock.lock()
        self.catalog = catalog
        self.token = Self.makeToken()
        lock.unlock()

        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = listener.port?.rawValue
                ready.signal()
            case .failed, .cancelled:
                ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener

        _ = ready.wait(timeout: .now() + 5)
        guard port != nil else {
            stop()
            throw MCPServerError.couldNotBind
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        lock.lock()
        catalog = nil
        token = ""
        lock.unlock()
    }

    /// The `--mcp-config` payload handed to the CLI for this run.
    func configurationJSON() -> String? {
        guard let endpoint else { return nil }
        let config: [String: Any] = [
            "mcpServers": [
                "cadence": [
                    "type": "http",
                    "url": endpoint,
                    "headers": ["Authorization": "Bearer \(token)"]
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if error != nil {
                connection.cancel()
                return
            }

            switch HTTPRequest.parse(accumulated) {
            case .incomplete:
                if isComplete {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: accumulated)
                }
            case .malformed:
                self.respond(connection, status: "400 Bad Request", body: Data())
            case .complete(let request):
                let response = self.handle(request)
                self.respond(connection, status: response.status, body: response.body)
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: Data) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Routing

    private struct Response {
        var status: String
        var body: Data
    }

    private func handle(_ request: HTTPRequest) -> Response {
        lock.lock()
        let expectedToken = token
        let catalog = self.catalog
        lock.unlock()

        // A browser page must never be able to reach this.
        if let origin = request.headers["origin"], !origin.hasPrefix("http://127.0.0.1") {
            return Response(status: "403 Forbidden", body: Data())
        }
        guard request.headers["authorization"] == "Bearer \(expectedToken)", !expectedToken.isEmpty else {
            return Response(status: "401 Unauthorized", body: Data())
        }
        guard request.method == "POST", request.path.hasPrefix("/mcp") else {
            return Response(status: "404 Not Found", body: Data())
        }
        guard let catalog else {
            return Response(status: "503 Service Unavailable", body: Data())
        }

        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return Response(status: "200 OK", body: encode(JSONRPC.error(id: nil, code: -32700, message: "Parse error")))
        }
        return Response(status: "200 OK", body: encode(dispatch(json, catalog: catalog)))
    }

    private func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    /// JSON-RPC 2.0. Notifications (no `id`) get an empty body.
    private func dispatch(_ request: [String: Any], catalog: ToolCatalog) -> [String: Any] {
        let id = request["id"]
        let method = request["method"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return JSONRPC.result(id: id, [
                "protocolVersion": "2025-06-18",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "cadence", "version": "0.1.0"]
            ])

        case "notifications/initialized", "notifications/cancelled":
            return [:]

        case "ping":
            return JSONRPC.result(id: id, [:])

        case "tools/list":
            return JSONRPC.result(id: id, [
                "tools": catalog.tools().map { tool in
                    [
                        "name": tool.name,
                        "description": tool.description,
                        "inputSchema": tool.inputSchema
                    ] as [String: Any]
                }
            ])

        case "tools/call":
            guard let name = params["name"] as? String else {
                return JSONRPC.error(id: id, code: -32602, message: "Missing tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            onToolCall?(name)
            do {
                let payload = try catalog.call(name, arguments: arguments)
                let text = String(
                    data: (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data(),
                    encoding: .utf8
                ) ?? "{}"
                return JSONRPC.result(id: id, [
                    "content": [["type": "text", "text": text]]
                ])
            } catch {
                // Reported as a tool error rather than a protocol error, so the
                // model can read the message and try again.
                return JSONRPC.result(id: id, [
                    "isError": true,
                    "content": [["type": "text", "text": error.localizedDescription]]
                ])
            }

        default:
            return JSONRPC.error(id: id, code: -32601, message: "Unknown method “\(method)”")
        }
    }
}

enum MCPServerError: LocalizedError {
    case couldNotBind

    var errorDescription: String? {
        switch self {
        case .couldNotBind: "Could not start the local MCP server."
        }
    }
}

// MARK: - JSON-RPC shapes

enum JSONRPC {
    static func result(id: Any?, _ value: [String: Any]) -> [String: Any] {
        var response: [String: Any] = ["jsonrpc": "2.0", "result": value]
        if let id { response["id"] = id }
        return response
    }

    static func error(id: Any?, code: Int, message: String) -> [String: Any] {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        response["id"] = id ?? NSNull()
        return response
    }
}

// MARK: - Just enough HTTP

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    enum ParseResult {
        case incomplete
        case malformed
        case complete(HTTPRequest)
    }

    /// Header names are lowercased. Only `Content-Length` bodies are supported —
    /// the CLI does not send chunked requests.
    static func parse(_ data: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else { return .incomplete }

        guard let headerText = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else {
            return .malformed
        }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .malformed }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .malformed }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let expected = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[headerEnd.upperBound...]
        guard body.count >= expected else { return .incomplete }

        return .complete(HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: String(requestLine[1]),
            headers: headers,
            body: Data(body.prefix(expected))
        ))
    }
}
