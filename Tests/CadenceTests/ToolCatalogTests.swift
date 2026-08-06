import XCTest
import GRDB
@testable import Cadence

final class ToolCatalogTests: XCTestCase {

    private var database: AppDatabase!
    private var buffer: ProposalBuffer!
    private var catalog: ToolCatalog!

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute))!
    }

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
        buffer = ProposalBuffer()
        catalog = ToolCatalog(
            database: database,
            buffer: buffer,
            context: PlanningContext(
                workdayStartHour: 9,
                workdayEndHour: 18,
                includesWeekends: false,
                defaultEstimateMinutes: 30,
                snapMinutes: 15,
                busy: [DateInterval(start: date(5, 10), end: date(5, 11))]
            ),
            calendar: calendar
        )
    }

    // MARK: - Helpers

    @discardableResult
    private func insert(
        _ title: String,
        status: TodoStatus = .todo,
        estimate: Int? = nil,
        dueAt: Date? = nil
    ) throws -> Todo {
        let todo = Todo(title: title, status: status, estimateMinutes: estimate, dueAt: dueAt)
        try database.writer.write { db in try TodoRepository.insert(db, todo) }
        return todo
    }

    private func call(_ name: String, _ args: [String: Any] = [:]) throws -> Any {
        try catalog.call(name, arguments: args)
    }

    private func dictionaries(_ value: Any) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }

    // MARK: - Descriptors

    func testEveryToolHasADescriptionAndObjectSchema() {
        let tools = catalog.tools()
        XCTAssertFalse(tools.isEmpty)
        for tool in tools {
            XCTAssertFalse(tool.description.isEmpty, "\(tool.name) has no description")
            XCTAssertEqual(tool.inputSchema["type"] as? String, "object", "\(tool.name)")
            XCTAssertNotNil(tool.inputSchema["properties"], "\(tool.name)")
        }
    }

    func testWriteToolsAreAllNamedPropose() {
        let writes = catalog.tools().map(\.name).filter {
            $0.hasPrefix("propose_")
        }
        XCTAssertEqual(Set(writes), [
            "propose_create_task", "propose_update_task", "propose_schedule",
            "propose_move_block", "propose_delete_block"
        ])
    }

    func testUnknownToolIsRejected() {
        XCTAssertThrowsError(try call("delete_everything"))
    }

    // MARK: - Read tools

    func testListTasksExcludesCompletedByDefault() throws {
        try insert("Open")
        try insert("Closed", status: .done)

        let titles = dictionaries(try call("list_tasks")).compactMap { $0["title"] as? String }
        XCTAssertEqual(titles, ["Open"])
    }

    func testListTasksUnscheduledOnly() throws {
        let scheduled = try insert("Scheduled")
        try insert("Not scheduled")
        try database.writer.write { db in
            try TodoRepository.insertBlock(db, TimeBlock(
                taskID: scheduled.id, startAt: date(5, 9), endAt: date(5, 10)
            ))
        }

        let titles = dictionaries(try call("list_tasks", ["unscheduledOnly": true]))
            .compactMap { $0["title"] as? String }
        XCTAssertEqual(titles, ["Not scheduled"])
    }

    func testListTasksRejectsAnUnknownStatus() {
        XCTAssertThrowsError(try call("list_tasks", ["status": "procrastinating"]))
    }

    func testGetTaskIncludesSubtasksAndBlocks() throws {
        let parent = try insert("Ship v2")
        let child = Todo(title: "Write docs", status: .todo, parentID: parent.id)
        try database.writer.write { db in
            try TodoRepository.insert(db, child)
            try TodoRepository.insertBlock(db, TimeBlock(
                taskID: parent.id, startAt: date(5, 9), endAt: date(5, 10)
            ))
        }

        let payload = try call("get_task", ["id": parent.id]) as? [String: Any]
        XCTAssertEqual(payload?["title"] as? String, "Ship v2")
        XCTAssertEqual(dictionaries(payload?["subtasks"] as Any).count, 1)
        XCTAssertEqual(dictionaries(payload?["blocks"] as Any).count, 1)
        XCTAssertEqual(payload?["scheduledMinutes"] as? Int, 60)
    }

    func testGetTaskOnAMissingIDReportsRatherThanThrows() throws {
        let payload = try call("get_task", ["id": "nope"]) as? [String: Any]
        XCTAssertNotNil(payload?["error"])
    }

    func testGetScheduleExposesBusyTimeWithoutEventTitles() throws {
        // Calendar events are opaque: the model learns when, never what.
        let payload = try call("get_schedule", [
            "from": ISO.string(date(5, 0)),
            "to": ISO.string(date(6, 0))
        ]) as? [String: Any]

        let busy = dictionaries(payload?["busy"] as Any)
        XCTAssertEqual(busy.count, 1)
        XCTAssertNil(busy.first?["title"])
        XCTAssertNotNil(busy.first?["start"])
    }

    func testGetScheduleRejectsABackwardsRange() {
        XCTAssertThrowsError(try call("get_schedule", [
            "from": ISO.string(date(6, 0)),
            "to": ISO.string(date(5, 0))
        ]))
    }

    // MARK: - find_free_slots

    func testFindFreeSlotsAvoidsBusyTime() throws {
        let payload = try call("find_free_slots", [
            "durationMinutes": 60,
            "from": ISO.string(date(5, 0)),
            "to": ISO.string(date(6, 0))
        ]) as? [String: Any]

        let slots = dictionaries(payload?["slots"] as Any)
        XCTAssertFalse(slots.isEmpty)
        for slot in slots {
            let start = ISO.date(slot["start"] as! String)!
            let end = ISO.date(slot["end"] as! String)!
            XCTAssertFalse(
                DateInterval(start: start, end: end)
                    .overlaps(DateInterval(start: date(5, 10), end: date(5, 11)))
            )
        }
    }

    func testFindFreeSlotsExplainsItselfWhenNothingFits() throws {
        let payload = try call("find_free_slots", [
            "durationMinutes": 600,
            "from": ISO.string(date(5, 0)),
            "to": ISO.string(date(6, 0))
        ]) as? [String: Any]

        XCTAssertTrue(dictionaries(payload?["slots"] as Any).isEmpty)
        XCTAssertNotNil(payload?["note"], "a bare empty list gives the model nothing to act on")
    }

    func testFindFreeSlotsRequiresItsArguments() {
        XCTAssertThrowsError(try call("find_free_slots", ["durationMinutes": 30]))
    }

    func testBareDatesAreAccepted() throws {
        // Models emit `2026-08-05` constantly; rejecting it would be hostile.
        let payload = try call("find_free_slots", [
            "durationMinutes": 30,
            "from": "2026-08-05",
            "to": "2026-08-06"
        ]) as? [String: Any]
        XCTAssertNotNil(payload?["slots"])
    }

    func testAGarbageDateIsRejectedWithAUsefulMessage() {
        XCTAssertThrowsError(try call("find_free_slots", [
            "durationMinutes": 30,
            "from": "next tuesday",
            "to": "2026-08-06"
        ])) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("ISO-8601"),
                "got: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Write tools stage only

    func testProposingATaskDoesNotTouchTheDatabase() throws {
        _ = try call("propose_create_task", ["title": "Only proposed", "estimateMinutes": 45])

        XCTAssertEqual(buffer.count, 1)
        let saved = try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task")
        }
        XCTAssertEqual(saved, 0, "propose_* must never write")
    }

    func testProposingAScheduleDoesNotTouchTheDatabase() throws {
        let todo = try insert("Schedule me")
        _ = try call("propose_schedule", [
            "taskID": todo.id,
            "start": ISO.string(date(5, 14)),
            "end": ISO.string(date(5, 15))
        ])

        XCTAssertEqual(buffer.count, 1)
        let blocks = try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM time_block")
        }
        XCTAssertEqual(blocks, 0)
    }

    func testProposeScheduleRejectsABackwardsInterval() throws {
        let todo = try insert("Backwards")
        XCTAssertThrowsError(try call("propose_schedule", [
            "taskID": todo.id,
            "start": ISO.string(date(5, 15)),
            "end": ISO.string(date(5, 14))
        ]))
        XCTAssertEqual(buffer.count, 0)
    }

    func testUpdatePatchOnlyCarriesTheFieldsThatWereSent() throws {
        let todo = try insert("Patch me", estimate: 30)
        _ = try call("propose_update_task", ["id": todo.id, "estimateMinutes": 90])

        let (changes, _, _) = buffer.drain()
        guard case .updateTask(_, let patch) = changes.first else {
            return XCTFail("expected an update")
        }
        XCTAssertEqual(patch.estimateMinutes, .some(.some(90)))
        XCTAssertNil(patch.title)
        XCTAssertNil(patch.dueAt, "an absent key must not be read as “clear this field”")
    }

    func testExplicitNullClearsAField() throws {
        let todo = try insert("Clear my due date", estimate: 30)
        _ = try call("propose_update_task", ["id": todo.id, "dueAt": NSNull()])

        let (changes, _, _) = buffer.drain()
        guard case .updateTask(_, let patch) = changes.first else {
            return XCTFail("expected an update")
        }
        XCTAssertEqual(patch.dueAt, .some(nil), "an explicit null should clear it")
    }

    func testExplainRecordsTheSummaryAndWarnings() throws {
        _ = try call("propose_create_task", ["title": "A"])
        _ = try call("explain", [
            "summary": "Made one task.",
            "warnings": ["Could not fit the other one"]
        ])

        let (changes, summary, warnings) = buffer.drain()
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(summary, "Made one task.")
        XCTAssertEqual(warnings, ["Could not fit the other one"])
    }

    func testDrainingEmptiesTheBuffer() throws {
        _ = try call("propose_create_task", ["title": "A"])
        _ = buffer.drain()
        XCTAssertEqual(buffer.count, 0)
    }
}
