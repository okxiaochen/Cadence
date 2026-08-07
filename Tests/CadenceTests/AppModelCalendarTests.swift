import XCTest
import GRDB
@testable import Cadence

/// Exercises the calendar write path end to end: schedule, move, resize,
/// duplicate, unschedule — and that each is a single undo step.
@MainActor
final class AppModelCalendarTests: XCTestCase {

    private var database: AppDatabase!
    private var model: AppModel!
    private var undo: UndoManager!

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
        model = AppModel(database: database)
        undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
    }

    override func tearDown() {
        model = nil
        database = nil
        undo = nil
    }

    // MARK: - Helpers

    /// Each wrapper opens its own undo group, which is what the run loop does
    /// for real user actions (`groupsByEvent`). Without it, every mutation in a
    /// test would land in one group and a single undo would revert the setup too.
    @discardableResult
    private func schedule(todoID: String, at date: Date, duration: Int? = nil) -> String? {
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        return model.schedule(todoID: todoID, at: date, duration: duration)
    }

    private func setBlockInterval(_ id: String, to interval: DateInterval, actionName: String = "Move Block") {
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        model.setBlockInterval(id, to: interval, actionName: actionName)
    }

    private func deleteBlock(_ id: String) {
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        model.deleteBlock(id)
    }

    private func makeTodo(
        _ title: String,
        status: TodoStatus = .todo,
        estimate: Int? = nil
    ) throws -> String {
        let todo = Todo(title: title, status: status, estimateMinutes: estimate)
        try database.writer.write { db in try TodoRepository.insert(db, todo) }
        return todo.id
    }

    private func blocks(forTask id: String) throws -> [TimeBlock] {
        try database.writer.read { db in
            try TimeBlock.fetchAll(
                db,
                sql: "SELECT * FROM time_block WHERE taskID = ? ORDER BY startAt",
                arguments: [id]
            )
        }
    }

    private func todo(_ id: String) throws -> Todo? {
        try database.writer.read { db in try TodoRepository.fetch(db, id: id) }
    }

    private let start = Date(timeIntervalSince1970: 1_785_000_000)

    // MARK: - Scheduling

    func testSchedulingUsesTheEstimateForDuration() throws {
        let id = try makeTodo("Write docs", estimate: 90)
        schedule(todoID: id, at: start)

        let created = try blocks(forTask: id)
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created[0].startAt, start)
        XCTAssertEqual(created[0].durationMinutes, 90)
    }

    func testSchedulingFallsBackToTheDefaultEstimate() throws {
        let id = try makeTodo("No estimate")
        schedule(todoID: id, at: start)
        XCTAssertEqual(try blocks(forTask: id).first?.durationMinutes,
                       Preferences.shared.defaultEstimateMinutes)
    }

    func testExplicitDurationWins() throws {
        let id = try makeTodo("Write docs", estimate: 90)
        schedule(todoID: id, at: start, duration: 30)
        XCTAssertEqual(try blocks(forTask: id).first?.durationMinutes, 30)
    }

    func testDroppingALegacyInboxTaskOntoTheGridTriagesIt() throws {
        // Rows written before the Inbox was retired can still carry the status.
        let id = try makeTodo("Captured", status: .inbox)
        schedule(todoID: id, at: start)
        XCTAssertEqual(try todo(id)?.status, .todo)
    }

    func testSchedulingDoesNotDisturbAnInProgressStatus() throws {
        let id = try makeTodo("Working on it", status: .doing)
        schedule(todoID: id, at: start)
        XCTAssertEqual(try todo(id)?.status, .doing)
    }

    // MARK: - Moving and resizing

    func testMovingABlockRewritesItsInterval() throws {
        let id = try makeTodo("Move me", estimate: 60)
        let blockID = schedule(todoID: id, at: start)!

        let moved = DateInterval(start: start.addingTimeInterval(7200), duration: 3600)
        setBlockInterval(blockID, to: moved)

        let stored = try blocks(forTask: id)[0]
        XCTAssertEqual(stored.startAt, moved.start)
        XCTAssertEqual(stored.endAt, moved.end)
    }

    func testResizingChangesOnlyTheEnd() throws {
        let id = try makeTodo("Resize me", estimate: 60)
        let blockID = schedule(todoID: id, at: start)!

        setBlockInterval(
            blockID,
            to: DateInterval(start: start, duration: 5400),
            actionName: "Resize Block"
        )

        let stored = try blocks(forTask: id)[0]
        XCTAssertEqual(stored.startAt, start)
        XCTAssertEqual(stored.durationMinutes, 90)
    }

    // MARK: - One task, one date

    func testSchedulingAgainReplacesRatherThanAccumulates() throws {
        let id = try makeTodo("Move me", estimate: 45)
        schedule(todoID: id, at: start)
        schedule(todoID: id, at: start.addingTimeInterval(86_400))

        let stored = try blocks(forTask: id)
        XCTAssertEqual(stored.count, 1, "a task has one date, so a second drop replaces the first")
        XCTAssertEqual(stored[0].startAt, start.addingTimeInterval(86_400))
    }

    func testSchedulingSetsTheTaskDate() throws {
        let id = try makeTodo("Schedule me")
        schedule(todoID: id, at: start)
        XCTAssertEqual(try todo(id)?.dueAt, start, "the date and the block are one thing")
    }

    func testMovingABlockMovesTheTaskDate() throws {
        let id = try makeTodo("Move me", estimate: 60)
        let blockID = schedule(todoID: id, at: start)!
        let moved = start.addingTimeInterval(7200)

        setBlockInterval(blockID, to: DateInterval(start: moved, duration: 3600))
        XCTAssertEqual(try todo(id)?.dueAt, moved)
    }

    func testUnschedulingKeepsTheDayButDropsTheTime() throws {
        let id = try makeTodo("Unschedule me")
        let blockID = schedule(todoID: id, at: start)!

        deleteBlock(blockID)

        XCTAssertTrue(try blocks(forTask: id).isEmpty)
        XCTAssertEqual(
            try todo(id)?.dueAt,
            Calendar.current.startOfDay(for: start),
            "it becomes an all-day item rather than losing its date"
        )
    }

    func testSettingADateWithATimeCreatesTheBlock() throws {
        let id = try makeTodo("When", estimate: 30)

        undo.beginUndoGrouping()
        model.setWhen(start, includesTime: true, for: [id])
        undo.endUndoGrouping()

        let stored = try blocks(forTask: id)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].startAt, start)
        XCTAssertEqual(try todo(id)?.dueAt, start)
    }

    func testSettingADateWithoutATimeIsAllDay() throws {
        let id = try makeTodo("All day")
        schedule(todoID: id, at: start)

        undo.beginUndoGrouping()
        model.setWhen(start, includesTime: false, for: [id])
        undo.endUndoGrouping()

        XCTAssertTrue(try blocks(forTask: id).isEmpty, "no time means no block")
        XCTAssertEqual(try todo(id)?.dueAt, Calendar.current.startOfDay(for: start))
    }

    func testClearingTheDateRemovesTheBlockToo() throws {
        let id = try makeTodo("Clear me")
        schedule(todoID: id, at: start)

        undo.beginUndoGrouping()
        model.setWhen(nil, includesTime: false, for: [id])
        undo.endUndoGrouping()

        XCTAssertTrue(try blocks(forTask: id).isEmpty)
        XCTAssertNil(try todo(id)?.dueAt)
    }

    func testUnschedulingRemovesTheBlockButKeepsTheTask() throws {
        let id = try makeTodo("Unschedule me")
        let blockID = schedule(todoID: id, at: start)!

        deleteBlock(blockID)

        XCTAssertTrue(try blocks(forTask: id).isEmpty)
        XCTAssertNotNil(try todo(id))
        XCTAssertNil(model.selectedBlockID)
    }

    // MARK: - Undo

    func testUndoRevertsAMove() throws {
        let id = try makeTodo("Move me", estimate: 60)
        let blockID = schedule(todoID: id, at: start)!

        setBlockInterval(blockID, to: DateInterval(start: start.addingTimeInterval(7200), duration: 3600))
        undo.undo()

        XCTAssertEqual(try blocks(forTask: id)[0].startAt, start)
    }

    func testUndoRestoresAnUnscheduledBlock() throws {
        let id = try makeTodo("Bring it back", estimate: 60)
        let blockID = schedule(todoID: id, at: start)!

        deleteBlock(blockID)
        XCTAssertTrue(try blocks(forTask: id).isEmpty)

        undo.undo()

        let restored = try blocks(forTask: id)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].id, blockID)
        XCTAssertEqual(restored[0].startAt, start)
    }

    func testUndoRemovesANewlyScheduledBlock() throws {
        let id = try makeTodo("Scheduled by mistake")
        schedule(todoID: id, at: start)
        XCTAssertEqual(try blocks(forTask: id).count, 1)

        undo.undo()
        XCTAssertTrue(try blocks(forTask: id).isEmpty)
    }

    func testRedoReappliesTheMove() throws {
        let id = try makeTodo("Move me", estimate: 60)
        let blockID = schedule(todoID: id, at: start)!
        let moved = start.addingTimeInterval(7200)

        setBlockInterval(blockID, to: DateInterval(start: moved, duration: 3600))
        undo.undo()
        XCTAssertEqual(try blocks(forTask: id)[0].startAt, start)

        undo.redo()
        XCTAssertEqual(try blocks(forTask: id)[0].startAt, moved)
    }

    // MARK: - Navigation and conflicts

    func testNavigationStepsByTheVisibleSpan() {
        model.calendarScale = .week
        let before = model.visibleDays
        model.stepCalendar(by: 1)
        let after = model.visibleDays

        XCTAssertEqual(after.count, 7)
        XCTAssertEqual(
            Calendar.current.dateComponents([.day], from: before[0], to: after[0]).day,
            7
        )

        model.goToToday()
        XCTAssertTrue(model.visibleDays.contains { Calendar.current.isDateInToday($0) })
    }

    func testVisibleRangeCoversEveryVisibleDay() {
        model.calendarScale = .threeDay
        let range = model.visibleRange
        XCTAssertEqual(range.duration, 3 * 86_400, accuracy: 3600)  // DST tolerance
        for day in model.visibleDays {
            XCTAssertTrue(range.contains(day))
        }
    }

    func testConflictIntervalsExcludeTheBlockBeingDragged() throws {
        let first = try makeTodo("First", estimate: 60)
        let second = try makeTodo("Second", estimate: 60)
        let firstBlock = schedule(todoID: first, at: start)!
        schedule(todoID: second, at: start.addingTimeInterval(1800))

        // Populate the in-memory cache the way the observation would.
        model.scheduledBlocks = try database.writer.read { db in
            try TodoRepository.scheduledBlocks(
                db,
                in: DateInterval(start: start.addingTimeInterval(-86_400), duration: 3 * 86_400)
            )
        }

        let dragged = DateInterval(start: start, duration: 3600)
        XCTAssertTrue(model.conflictIntervals(excluding: nil).contains { $0.overlaps(dragged) })

        // Excluding itself, the overlap with "Second" still stands.
        let others = model.conflictIntervals(excluding: firstBlock)
        XCTAssertTrue(others.contains { $0.overlaps(dragged) })
        XCTAssertFalse(others.contains { $0 == dragged })
    }

    // MARK: - Duration

    func testSettingDurationKeepsTheStart() throws {
        let id = try makeTodo("Stretch me", estimate: 30)
        let blockID = schedule(todoID: id, at: start)!

        undo.beginUndoGrouping()
        model.setBlockDuration(blockID, minutes: 90)
        undo.endUndoGrouping()

        let stored = try blocks(forTask: id)[0]
        XCTAssertEqual(stored.startAt, start)
        XCTAssertEqual(stored.durationMinutes, 90)
    }

    func testDurationIsClampedToTheEndOfTheDay() throws {
        let id = try makeTodo("Late one")
        let lateStart = Calendar.current.date(
            bySettingHour: 23, minute: 0, second: 0, of: start
        )!
        let blockID = schedule(todoID: id, at: lateStart, duration: 30)!

        undo.beginUndoGrouping()
        model.setBlockDuration(blockID, minutes: 240)
        undo.endUndoGrouping()

        let stored = try blocks(forTask: id)[0]
        XCTAssertEqual(stored.durationMinutes, 60)
        XCTAssertEqual(stored.endAt, Calendar.current.startOfDay(for: lateStart).addingTimeInterval(86_400))
    }

    // MARK: - Moving between days

    func testDroppingOnADayKeepsTheTimeOfDay() throws {
        let id = try makeTodo("Standup", estimate: 30)
        let tenAM = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: start)!
        schedule(todoID: id, at: tenAM)

        let threeDaysOn = Calendar.current.date(byAdding: .day, value: 3, to: tenAM)!
        undo.beginUndoGrouping()
        model.moveToDay(threeDaysOn, for: [id])
        undo.endUndoGrouping()

        let moved = try XCTUnwrap(try blocks(forTask: id).first)
        let time = Calendar.current.dateComponents([.hour, .minute], from: moved.startAt)
        XCTAssertEqual(time.hour, 10, "the day changes, the time of day does not")
        XCTAssertEqual(moved.durationMinutes, 30)
        XCTAssertTrue(Calendar.current.isDate(moved.startAt, inSameDayAs: threeDaysOn))
    }

    func testDroppingAnAllDayTaskOnADayStaysAllDay() throws {
        let id = try makeTodo("All day")
        undo.beginUndoGrouping()
        model.setWhen(start, includesTime: false, for: [id])
        undo.endUndoGrouping()

        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        undo.beginUndoGrouping()
        model.moveToDay(tomorrow, for: [id])
        undo.endUndoGrouping()

        XCTAssertTrue(try blocks(forTask: id).isEmpty, "no time before, no time after")
        XCTAssertEqual(try todo(id)?.dueAt, Calendar.current.startOfDay(for: tomorrow))
    }

    // MARK: - Estimate and duration are one value

    func testSchedulingSetsTheEstimateFromTheBlock() throws {
        let id = try makeTodo("No estimate yet")
        schedule(todoID: id, at: start, duration: 45)
        XCTAssertEqual(try todo(id)?.estimateMinutes, 45)
    }

    func testResizingABlockChangesTheEstimate() throws {
        let id = try makeTodo("Grow me", estimate: 30)
        let blockID = schedule(todoID: id, at: start)!

        setBlockInterval(
            blockID,
            to: DateInterval(start: start, duration: 5400),
            actionName: "Resize Block"
        )
        XCTAssertEqual(try todo(id)?.estimateMinutes, 90, "dragging longer means it takes longer")
    }

    func testChangingTheEstimateResizesTheBlock() throws {
        let id = try makeTodo("Stretch me", estimate: 30)
        schedule(todoID: id, at: start)

        undo.beginUndoGrouping()
        model.setEstimate(120, for: [id])
        undo.endUndoGrouping()

        let block = try XCTUnwrap(try blocks(forTask: id).first)
        XCTAssertEqual(block.durationMinutes, 120)
        XCTAssertEqual(block.startAt, start, "the start is held; the end moves")
    }

    func testTheEstimateOfAnUnscheduledTaskIsJustANumber() throws {
        let id = try makeTodo("Not scheduled")

        undo.beginUndoGrouping()
        model.setEstimate(90, for: [id])
        undo.endUndoGrouping()

        XCTAssertEqual(try todo(id)?.estimateMinutes, 90)
        XCTAssertTrue(try blocks(forTask: id).isEmpty)
    }

    func testAnEstimateCannotPushABlockPastMidnight() throws {
        let id = try makeTodo("Late")
        let late = Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: start)!
        schedule(todoID: id, at: late, duration: 30)

        undo.beginUndoGrouping()
        model.setEstimate(240, for: [id])
        undo.endUndoGrouping()

        let block = try XCTUnwrap(try blocks(forTask: id).first)
        XCTAssertEqual(block.durationMinutes, 60)
    }

    // MARK: - Snooze

    func testSnoozeMovesTheBlockKeepingItsLength() throws {
        let id = try makeTodo("Later", estimate: 30)
        schedule(todoID: id, at: start)

        undo.beginUndoGrouping()
        model.snooze(taskID: id, byMinutes: 10)
        undo.endUndoGrouping()

        let block = try XCTUnwrap(try blocks(forTask: id).first)
        XCTAssertEqual(block.startAt, start.addingTimeInterval(600))
        XCTAssertEqual(block.durationMinutes, 30)
    }

    func testSnoozeRefusesToPushABlockPastMidnight() throws {
        let id = try makeTodo("Nearly midnight")
        let late = Calendar.current.date(bySettingHour: 23, minute: 45, second: 0, of: start)!
        schedule(todoID: id, at: late, duration: 15)

        undo.beginUndoGrouping()
        model.snooze(taskID: id, byMinutes: 30)
        undo.endUndoGrouping()

        // Better to leave it where it is than to have it vanish from its day.
        XCTAssertEqual(try blocks(forTask: id).first?.startAt, late)
    }

    // MARK: - Context inheritance

    /// `createTodo` registers undo like any other mutation, so tests must open
    /// a group the way the run loop does for a real action.
    private func create(_ title: String, dueAt: Date? = nil) -> String? {
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        return model.createTodo(title: title, dueAt: dueAt)
    }

    func testANewTaskInheritsTheDayFromTheListYouAreLookingAt() throws {
        model.query.selection = .smart(.today)
        let id = try XCTUnwrap(create("From Today"))
        XCTAssertEqual(
            try todo(id)?.dueAt,
            Calendar.current.startOfDay(for: Date())
        )
    }

    func testUpcomingFilesNewWorkForTomorrow() throws {
        model.query.selection = .smart(.upcoming)
        let id = try XCTUnwrap(create("From Upcoming"))
        let tomorrow = Calendar.current.date(
            byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())
        )
        XCTAssertEqual(try todo(id)?.dueAt, tomorrow)
    }

    func testAListThatIsNotADayLeavesTheDateAlone() throws {
        model.query.selection = .smart(.anytime)
        let id = try XCTUnwrap(create("Undated"))
        XCTAssertNil(try todo(id)?.dueAt, "a project or Anytime says nothing about when")
    }

    func testATypedDateBeatsTheList() throws {
        model.query.selection = .smart(.today)
        let explicit = Calendar.current.date(byAdding: .day, value: 5, to: start)!
        let id = try XCTUnwrap(create("Explicit", dueAt: explicit))
        XCTAssertEqual(try todo(id)?.dueAt, explicit)
    }
}
