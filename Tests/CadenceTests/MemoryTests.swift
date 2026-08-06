import XCTest
import GRDB
@testable import Cadence

/// The memory layer's whole job is to stay small, stay current, and never end
/// up holding two contradictory beliefs at once.
final class MemoryTests: XCTestCase {

    private var database: AppDatabase!
    private var buffer: ProposalBuffer!
    private var catalog: ToolCatalog!

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
        buffer = ProposalBuffer()
        catalog = ToolCatalog(
            database: database,
            buffer: buffer,
            context: PlanningContext(
                workdayStartHour: 9, workdayEndHour: 18, includesWeekends: false,
                defaultEstimateMinutes: 30, snapMinutes: 15, busy: []
            )
        )
    }

    @discardableResult
    private func call(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
        try catalog.call(name, arguments: args) as? [String: Any] ?? [:]
    }

    private func all() throws -> [Memory] {
        try database.writer.read { db in try MemoryRepository.all(db) }
    }

    // MARK: - Writing

    func testRememberSavesImmediately() throws {
        let result = try call("remember", [
            "key": "meeting-time-preference",
            "category": "preference",
            "title": "Meeting times",
            "summary": "Dislikes meetings before 10am"
        ])

        XCTAssertEqual(result["saved"] as? Bool, true)
        XCTAssertEqual(result["revised"] as? Bool, false)
        // Unlike task changes, memory is not staged for review.
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(try all().count, 1)
    }

    func testRememberRejectsAnUnknownCategory() {
        XCTAssertThrowsError(try call("remember", [
            "key": "k", "category": "vibes", "title": "T", "summary": "S"
        ]))
    }

    // MARK: - Self-correction

    func testWritingTheSameKeyReplacesRatherThanDuplicates() throws {
        try call("remember", [
            "key": "meeting-time-preference",
            "category": "preference",
            "title": "Meeting times",
            "summary": "Dislikes meetings before 10am"
        ])
        let second = try call("remember", [
            "key": "meeting-time-preference",
            "category": "preference",
            "title": "Meeting times",
            "summary": "Now happy with early meetings"
        ])

        XCTAssertEqual(second["revised"] as? Bool, true)
        let memories = try all()
        XCTAssertEqual(memories.count, 1, "a changed mind must not leave both beliefs behind")
        XCTAssertEqual(memories[0].summary, "Now happy with early meetings")
    }

    func testRevisingKeepsTheOriginalCreationDateAndMovesUpdatedAt() throws {
        try call("remember", [
            "key": "project-a", "category": "project",
            "title": "Project A", "summary": "High priority this quarter"
        ])
        let first = try XCTUnwrap(try all().first)

        try call("remember", [
            "key": "project-a", "category": "project",
            "title": "Project A", "summary": "Deprioritised — paused until next year"
        ])
        let second = try XCTUnwrap(try all().first)

        XCTAssertEqual(second.createdAt, first.createdAt)
        XCTAssertGreaterThanOrEqual(second.updatedAt, first.updatedAt)
        XCTAssertEqual(second.summary, "Deprioritised — paused until next year")
    }

    func testKeysAreNormalisedSoNearMissesStillOverwrite() throws {
        try call("remember", [
            "key": "Meeting Time Preference", "category": "preference",
            "title": "T", "summary": "first"
        ])
        try call("remember", [
            "key": "meeting-time-preference", "category": "preference",
            "title": "T", "summary": "second"
        ])
        // Without normalisation these become two contradicting memories.
        XCTAssertEqual(try all().count, 1)
        XCTAssertEqual(try all()[0].summary, "second")
    }

    func testSlugNormalisation() {
        XCTAssertEqual(ToolCatalog.slug("Meeting Times!"), "meeting-times")
        XCTAssertEqual(ToolCatalog.slug("--already-a-slug--"), "already-a-slug")
        XCTAssertEqual(ToolCatalog.slug("Project A / B"), "project-a-b")
    }

    func testForgetRemovesIt() throws {
        try call("remember", ["key": "k", "category": "goal", "title": "T", "summary": "S"])
        let result = try call("forget", ["key": "k"])
        XCTAssertEqual(result["forgotten"] as? Bool, true)
        XCTAssertTrue(try all().isEmpty)
    }

    func testForgettingSomethingUnknownIsReportedNotThrown() throws {
        XCTAssertEqual(try call("forget", ["key": "never-existed"])["forgotten"] as? Bool, false)
    }

    // MARK: - Reading

    func testGetMemoryReturnsTheBodyAndBumpsRecency() throws {
        try call("remember", [
            "key": "k", "category": "project", "title": "T",
            "summary": "one line", "body": "the long version"
        ])
        XCTAssertNil(try all()[0].lastUsedAt)

        let result = try call("get_memory", ["key": "k"])
        XCTAssertEqual(result["body"] as? String, "the long version")
        XCTAssertNotNil(try all()[0].lastUsedAt, "reading a memory should mark it as used")
    }

    func testGetMemoryOnAnUnknownKeyReportsRatherThanThrows() throws {
        XCTAssertNotNil(try call("get_memory", ["key": "nope"])["error"])
    }

    func testSearchFindsByAnyField() throws {
        try call("remember", [
            "key": "deep-work", "category": "routine", "title": "Focus blocks",
            "summary": "Prefers long uninterrupted mornings", "body": "Two hours minimum"
        ])
        let hits = try catalog.call("search_memories", arguments: ["query": "uninterrupted"])
        XCTAssertEqual((hits as? [[String: Any]])?.count, 1)
    }

    // MARK: - Prompt budget

    func testOutlineIsOneLinePerMemory() throws {
        for index in 0..<5 {
            try call("remember", [
                "key": "k\(index)", "category": "preference",
                "title": "Title \(index)", "summary": "Summary \(index)",
                "body": "A very long body that must never reach the prompt \(index)"
            ])
        }
        let section = try database.writer.read { db in try MemoryRepository.promptSection(db) }

        XCTAssertTrue(section.contains("Summary 3"))
        XCTAssertFalse(
            section.contains("A very long body"),
            "unpinned bodies must stay out of the prompt"
        )
    }

    func testPinnedMemoriesAreIncludedInFull() throws {
        try call("remember", [
            "key": "pinned-one", "category": "constraint", "title": "No Friday meetings",
            "summary": "Fridays are for deep work", "body": "Absolutely no exceptions",
            "pinned": true
        ])
        let section = try database.writer.read { db in try MemoryRepository.promptSection(db) }
        XCTAssertTrue(section.contains("Absolutely no exceptions"))
    }

    func testOutlineIsCappedSoMemoryCannotCrowdOutTheRequest() throws {
        for index in 0..<80 {
            try call("remember", [
                "key": "k\(index)", "category": "preference",
                "title": "Title \(index)", "summary": String(repeating: "x", count: 60)
            ])
        }
        let section = try database.writer.read { db in
            try MemoryRepository.promptSection(db, maxOutlineEntries: 30, maxCharacters: 2_000)
        }
        XCTAssertLessThanOrEqual(section.count, 2_100)
        XCTAssertTrue(section.contains("search_memories"))
    }

    func testEmptyMemoryProducesNoPromptSection() throws {
        XCTAssertTrue(try database.writer.read { db in try MemoryRepository.promptSection(db) }.isEmpty)
    }

    func testMemoryToolsAreAdvertised() {
        let names = catalog.tools().map(\.name)
        for tool in ["remember", "forget", "get_memory", "search_memories"] {
            XCTAssertTrue(names.contains(tool), "missing \(tool)")
        }
    }
}
