import XCTest
@testable import Cadence

/// Drives the real server over a real loopback socket — HTTP framing, auth and
/// JSON-RPC are exactly what the CLI will hit.
final class MCPServerTests: XCTestCase {

    private var database: AppDatabase!
    private var server: MCPServer!
    private var buffer: ProposalBuffer!

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
        buffer = ProposalBuffer()
        server = MCPServer()
        try server.start(catalog: ToolCatalog(
            database: database,
            buffer: buffer,
            context: PlanningContext(
                workdayStartHour: 9, workdayEndHour: 18, includesWeekends: false,
                defaultEstimateMinutes: 30, snapMinutes: 15, busy: []
            )
        ))
    }

    override func tearDown() {
        server.stop()
        server = nil
        database = nil
    }

    // MARK: - Transport

    private func post(
        _ body: [String: Any],
        token: String? = nil,
        origin: String? = nil,
        path: String = "/mcp",
        method: String = "POST"
    ) throws -> (status: Int, json: [String: Any]?) {
        let url = URL(string: "http://127.0.0.1:\(server.port!)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("Bearer \(token ?? server.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }

        var status = 0
        var payload: [String: Any]?
        let done = expectation(description: "response")

        URLSession.shared.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let data, !data.isEmpty {
                payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            done.fulfill()
        }.resume()

        wait(for: [done], timeout: 10)
        return (status, payload)
    }

    private func callTool(_ name: String, _ arguments: [String: Any] = [:]) throws -> [String: Any]? {
        let response = try post([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": name, "arguments": arguments]
        ])
        guard let result = response.json?["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String,
              let data = text.data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Lifecycle

    func testServerBindsToLoopback() {
        XCTAssertNotNil(server.port)
        XCTAssertEqual(server.endpoint, "http://127.0.0.1:\(server.port!)/mcp")
        XCTAssertFalse(server.token.isEmpty)
    }

    func testConfigurationJSONCarriesTheEndpointAndToken() throws {
        let json = try XCTUnwrap(server.configurationJSON())
        XCTAssertTrue(json.contains("127.0.0.1"))
        XCTAssertTrue(json.contains(server.token))

        let parsed = try JSONSerialization.jsonObject(
            with: XCTUnwrap(json.data(using: .utf8))
        ) as? [String: Any]
        XCTAssertNotNil((parsed?["mcpServers"] as? [String: Any])?["cadence"])
    }

    // MARK: - Security

    func testRequestsWithoutTheTokenAreRejected() throws {
        let response = try post(["jsonrpc": "2.0", "id": 1, "method": "ping"], token: "wrong")
        XCTAssertEqual(response.status, 401)
    }

    func testBrowserOriginsAreRejected() throws {
        let response = try post(
            ["jsonrpc": "2.0", "id": 1, "method": "ping"],
            origin: "https://evil.example.com"
        )
        XCTAssertEqual(response.status, 403)
    }

    func testOtherPathsAreNotFound() throws {
        let response = try post(["jsonrpc": "2.0", "id": 1, "method": "ping"], path: "/admin")
        XCTAssertEqual(response.status, 404)
    }

    func testStoppingRevokesTheToken() throws {
        let token = server.token
        server.stop()
        XCTAssertTrue(server.token.isEmpty)
        XCTAssertNotEqual(token, server.token)
    }

    // MARK: - Protocol

    func testInitializeAdvertisesTools() throws {
        let response = try post(["jsonrpc": "2.0", "id": 1, "method": "initialize"])
        let result = response.json?["result"] as? [String: Any]
        XCTAssertNotNil(result?["protocolVersion"])
        XCTAssertNotNil((result?["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual((result?["serverInfo"] as? [String: Any])?["name"] as? String, "cadence")
    }

    func testToolsListReturnsTheCatalog() throws {
        let response = try post(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = (response.json?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        let names = tools?.compactMap { $0["name"] as? String } ?? []

        XCTAssertTrue(names.contains("find_free_slots"))
        XCTAssertTrue(names.contains("propose_schedule"))
        XCTAssertTrue(names.contains("explain"))
    }

    func testUnknownMethodIsAProtocolError() throws {
        let response = try post(["jsonrpc": "2.0", "id": 3, "method": "tools/destroy"])
        let error = response.json?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32601)
    }

    func testMalformedJSONGetsAParseError() throws {
        // Hand-rolled request so the body is deliberately not JSON.
        let url = URL(string: "http://127.0.0.1:\(server.port!)/mcp")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{ not json".utf8)
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")

        var payload: [String: Any]?
        let done = expectation(description: "response")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)

        XCTAssertEqual((payload?["error"] as? [String: Any])?["code"] as? Int, -32700)
    }

    func testNotificationsGetNoResponseBody() throws {
        let response = try post(["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertEqual(response.status, 200)
        XCTAssertNil(response.json?["result"])
        XCTAssertNil(response.json?["error"])
    }

    // MARK: - Tools over the wire

    func testCallingAReadToolReturnsData() throws {
        let todo = Todo(title: "Over the wire", status: .todo)
        try database.writer.write { db in try TodoRepository.insert(db, todo) }

        let response = try post([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "list_tasks", "arguments": [:] as [String: Any]]
        ])
        let content = ((response.json?["result"] as? [String: Any])?["content"] as? [[String: Any]])
        let text = content?.first?["text"] as? String
        XCTAssertTrue(text?.contains("Over the wire") ?? false)
    }

    func testAToolErrorComesBackAsAToolErrorNotAProtocolError() throws {
        let response = try post([
            "jsonrpc": "2.0", "id": 5, "method": "tools/call",
            "params": ["name": "get_task", "arguments": [:] as [String: Any]]
        ])
        let result = response.json?["result"] as? [String: Any]
        // The model should be able to read the message and retry.
        XCTAssertEqual(result?["isError"] as? Bool, true)
        XCTAssertNil(response.json?["error"])
    }

    func testProposeToolsStageThroughTheWireWithoutWriting() throws {
        _ = try callTool("propose_create_task", ["title": "Staged remotely"])

        XCTAssertEqual(buffer.count, 1)
        let saved = try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task")
        }
        XCTAssertEqual(saved, 0)
    }

    func testToolCallsAreReportedForTheProgressPanel() throws {
        let seen = ToolCallRecorder()
        server.onToolCall = { name in seen.record(name) }

        _ = try callTool("list_projects")
        _ = try callTool("list_tags")

        XCTAssertEqual(seen.names, ["list_projects", "list_tags"])
    }
}

private final class ToolCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var names: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func record(_ name: String) { lock.lock(); storage.append(name); lock.unlock() }
}
