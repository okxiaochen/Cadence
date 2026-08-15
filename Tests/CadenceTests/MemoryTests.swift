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
        for tool in [
            "remember", "forget", "get_memory", "search_memories",
            "list_stale_memories", "confirm_memory"
        ] {
            XCTAssertTrue(names.contains(tool), "missing \(tool)")
        }
    }

    // MARK: - Provenance
    //
    // The distinction the whole feature rests on: something the user told us
    // stays true until they say otherwise, because there is nothing to check it
    // against. Something inferred, or read out of another system, describes a
    // world that moves.

    private func store(
        _ key: String,
        source: String,
        verifiedAt: Date?
    ) throws {
        var memory = Memory(
            id: key, category: "project", title: key, summary: "about \(key)"
        )
        memory.source = source
        try database.writer.write { db in try MemoryRepository.upsert(db, memory) }
        // upsert stamps `now`, so an old verification has to be written after.
        if let verifiedAt {
            try database.writer.write { db in
                try db.execute(
                    sql: "UPDATE memory SET verifiedAt = ? WHERE id = ?",
                    arguments: [verifiedAt, key]
                )
            }
        }
    }

    private func daysAgo(_ days: Int) -> Date {
        Date().addingTimeInterval(-Double(days) * 86_400)
    }

    func testWhatTheUserToldUsNeverGoesStale() throws {
        try store("dislikes-mornings", source: Memory.Source.user, verifiedAt: daysAgo(400))
        let memory = try XCTUnwrap(all().first)
        XCTAssertFalse(memory.canGoStale)
        XCTAssertFalse(memory.isStale())
        XCTAssertNil(memory.daysSinceVerified(), "there is nothing to re-check it against")
    }

    func testAnInferredFactGoesStale() throws {
        try store("sprint-length", source: Memory.Source.inferred, verifiedAt: daysAgo(30))
        let memory = try XCTUnwrap(all().first)
        XCTAssertTrue(memory.isStale())
        XCTAssertEqual(memory.daysSinceVerified(), 30)
    }

    func testSomethingReadOutOfAConnectorGoesStaleToo() throws {
        try store("meego-space", source: "meegle", verifiedAt: daysAgo(30))
        XCTAssertTrue(try XCTUnwrap(all().first).isStale())
    }

    func testListStaleMemoriesLeavesSelfReportedOnesAlone() throws {
        try store("said-so", source: Memory.Source.user, verifiedAt: daysAgo(400))
        try store("worked-out", source: Memory.Source.inferred, verifiedAt: daysAgo(400))
        let result = try call("list_stale_memories", [:])
        let keys = (result["memories"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String }
        XCTAssertEqual(keys, ["worked-out"])
    }

    func testStaleMemoriesComeBackOldestFirst() throws {
        try store("recent", source: Memory.Source.inferred, verifiedAt: daysAgo(20))
        try store("ancient", source: Memory.Source.inferred, verifiedAt: daysAgo(90))
        let result = try call("list_stale_memories", [:])
        let keys = (result["memories"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String }
        XCTAssertEqual(keys, ["ancient", "recent"])
    }

    func testConfirmingRestartsTheClockWithoutRewritingTheNote() throws {
        try store("sprint-length", source: Memory.Source.inferred, verifiedAt: daysAgo(90))
        XCTAssertEqual(try call("confirm_memory", ["key": "sprint-length"])["confirmed"] as? Bool, true)

        let memory = try XCTUnwrap(all().first)
        XCTAssertFalse(memory.isStale())
        XCTAssertEqual(memory.summary, "about sprint-length", "confirming must not reword it")
    }

    func testConfirmingSomethingThatIsNotThereSaysSo() throws {
        XCTAssertEqual(try call("confirm_memory", ["key": "nope"])["confirmed"] as? Bool, false)
    }

    /// Re-stating a fact is itself a verification, so a stale memory clears
    /// without a separate step.
    func testRewritingAMemoryAlsoRestartsTheClock() throws {
        try store("sprint-length", source: Memory.Source.inferred, verifiedAt: daysAgo(90))
        try call("remember", [
            "key": "sprint-length", "category": "project",
            "title": "Sprint length", "summary": "three weeks now",
            "source": "inferred"
        ])
        XCTAssertFalse(try XCTUnwrap(all().first).isStale())
    }

    func testAnUnqualifiedRememberIsTreatedAsSelfReported() throws {
        // The honest reading of an unqualified claim, and the one that costs
        // nothing when the model simply omits the argument.
        try call("remember", [
            "key": "k", "category": "preference", "title": "T", "summary": "S"
        ])
        XCTAssertEqual(try XCTUnwrap(all().first).source, Memory.Source.user)
    }

    func testTheOutlineWarnsWhenAFactIsUnverified() throws {
        // Marked where the fact is read, not left to a tool call — a model that
        // has to ask whether something is current will use it as though it is.
        try store("sprint-length", source: Memory.Source.inferred, verifiedAt: daysAgo(90))
        let section = try database.writer.read { db in try MemoryRepository.promptSection(db) }
        XCTAssertTrue(section.contains("UNVERIFIED"), section)
        XCTAssertTrue(section.contains("inferred"), section)
    }

    func testTheOutlineSaysNothingAboutFreshOrSelfReportedFacts() throws {
        try store("said-so", source: Memory.Source.user, verifiedAt: daysAgo(400))
        try store("checked", source: Memory.Source.inferred, verifiedAt: daysAgo(1))
        let section = try database.writer.read { db in try MemoryRepository.promptSection(db) }
        XCTAssertFalse(section.contains("UNVERIFIED"), section)
    }
}
