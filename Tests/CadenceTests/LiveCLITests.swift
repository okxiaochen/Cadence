import XCTest
@testable import Cadence

/// End-to-end against the *real* AI CLI: app → MCP server → model → tool calls
/// → staged proposal. Skipped unless `CADENCE_LIVE_CLI=1`, because it spends
/// tokens on the user's subscription and needs network.
///
///     CADENCE_LIVE_CLI=1 xcodebuild test \
///       -only-testing:CadenceTests/LiveCLITests
@MainActor
final class LiveCLITests: XCTestCase {

    private var database: AppDatabase!
    private var model: AppModel!
    private var session: AgentSession!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CADENCE_LIVE_CLI"] == "1",
            "set CADENCE_LIVE_CLI=1 to run against the real CLI"
        )
        database = try AppDatabase.inMemory()
        model = AppModel(database: database)
        model.undoManager = UndoManager()
        session = AgentSession(model: model)
    }

    /// Polls rather than awaits: `send` deliberately fires a detached task so
    /// the UI stays responsive.
    private func waitForRun(timeout: TimeInterval = 180) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while session.status.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertFalse(session.status.isRunning, "run did not finish within \(Int(timeout))s")
    }

    func testCLIIsReachable() async throws {
        XCTAssertNil(session.configurationProblem, "CLI not found on PATH")
        let result = await session.testConnection()
        XCTAssertFalse(result.contains("Exit code"), result)
        print("[live] test connection → \(result)")
    }

    /// The real proof: the model must call our MCP tools and stage a block that
    /// dodges busy time, without ever writing to the database itself.
    func testSchedulingRunUsesOurToolsAndStagesAProposal() async throws {
        let todo = Todo(
            title: "Write the design document",
            status: .todo,
            estimateMinutes: 60
        )
        try await database.writer.write { db in try TodoRepository.insert(db, todo) }

        await session.send(
            "Schedule my unscheduled tasks for tomorrow.",
            surface: .schedule
        )
        try await waitForRun()

        print("[live] command: \(session.commandLine)")
        print("[live] tools called: \(session.toolCalls)")
        print("[live] output: \(session.rawOutput.prefix(600))")

        if case .failed(let message) = session.status {
            XCTFail("run failed: \(message)")
            return
        }

        XCTAssertFalse(session.toolCalls.isEmpty, "the model never reached our MCP server")
        XCTAssertTrue(
            session.toolCalls.contains("find_free_slots"),
            "expected find_free_slots; got \(session.toolCalls)"
        )

        let proposal = try await XCTUnwrap(session.proposal, "no proposal was staged")
        print("[live] proposal: \(proposal.summary)")
        for change in proposal.changes {
            print("[live]   \(change.summary) — \(change.detail ?? "") \(change.rejection ?? "")")
        }
        XCTAssertFalse(proposal.changes.isEmpty)

        // Nothing may have been written before review.
        let blocks = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM time_block")
        }
        XCTAssertEqual(blocks, 0, "propose_* wrote to the database")

        // And applying it must land exactly what was reviewed.
        let applied = await model.apply(proposal)
        let after = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM time_block")
        }
        XCTAssertEqual(after, proposal.applicableChanges.filter { $0.change.isScheduling }.count)
        print("[live] applied \(applied) changes")
    }

    /// The claim under test: telling the assistant something new should *revise*
    /// the old memory, not leave two contradictory ones behind.
    func testMemoryCorrectsItselfWhenThePreferenceChanges() async throws {
        await session.send(
            "Remember that I hate meetings before 10am — save it as a preference.",
            surface: .chat
        )
        try await waitForRun()

        var memories = try await database.writer.read { db in try MemoryRepository.all(db) }
        print("[live] after first: \(memories.map { "\($0.id) = \($0.summary)" })")
        XCTAssertEqual(memories.count, 1, "expected exactly one memory")
        let originalKey = try XCTUnwrap(memories.first?.id)

        await session.send(
            "Actually I've changed my mind — early meetings are fine now, I like "
                + "getting them out of the way. Update what you remember.",
            surface: .chat
        )
        try await waitForRun()

        memories = try await database.writer.read { db in try MemoryRepository.all(db) }
        print("[live] after second: \(memories.map { "\($0.id) = \($0.summary)" })")

        XCTAssertEqual(
            memories.count, 1,
            "a changed mind must revise the memory, not add a contradicting one"
        )
        XCTAssertEqual(memories.first?.id, originalKey, "it should reuse the same key")
        XCTAssertFalse(
            memories.first?.summary.localizedCaseInsensitiveContains("hate") ?? true,
            "the stale belief survived: \(memories.first?.summary ?? "")"
        )
    }
}
