import XCTest
import GRDB
@testable import Cadence

/// The timeline: time actually spent, and notes on where the work got to.
final class ProgressTests: XCTestCase {

    private var database: AppDatabase!

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 12) -> Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 8, day: day, hour: hour, minute: minute
        ))!
    }

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
    }

    @discardableResult
    private func insert(_ title: String, status: TodoStatus = .todo) throws -> Todo {
        try database.writer.write { db in
            try TodoRepository.insert(db, Todo(title: title, status: status))
        }
    }

    // MARK: - Timer

    func testSeveralTasksCanBeTimedAtOnce() throws {
        let first = try insert("Write the release notes")
        let second = try insert("Fix the flaky test")

        try database.writer.write { db in
            try ProgressRepository.startSession(db, taskID: first.id, at: at(9))
            try ProgressRepository.startSession(db, taskID: second.id, at: at(10))
        }

        let running = try database.writer.read { db in try ProgressRepository.running(db) }
        XCTAssertEqual(running.count, 2, "work interleaves; both clocks keep running")
        XCTAssertEqual(running.map(\.taskID), [second.id, first.id], "newest first")
    }

    func testStartingATimerCanBeMadeToStopTheOthers() throws {
        let first = try insert("Write the release notes")
        let second = try insert("Fix the flaky test")

        try database.writer.write { db in
            try ProgressRepository.startSession(db, taskID: first.id, at: at(9))
            try ProgressRepository.startSession(db, taskID: second.id, at: at(10), stoppingOthers: true)
        }

        try database.writer.read { db in
            let running = try ProgressRepository.running(db)
            XCTAssertEqual(running.map(\.taskID), [second.id], "only the newest session runs")

            let closed = try ProgressRepository.entries(db, taskID: first.id)
            XCTAssertEqual(closed.count, 1)
            XCTAssertEqual(closed[0].endedAt, at(10), "the old one is closed at the new one's start")
            XCTAssertEqual(closed[0].minutes(), 60)
        }
    }

    func testStartingATaskThatIsAlreadyRunningDoesNotStartASecondClock() throws {
        let todo = try insert("Write the release notes")
        try database.writer.write { db in
            try ProgressRepository.startSession(db, taskID: todo.id, at: at(9))
            try ProgressRepository.startSession(db, taskID: todo.id, at: at(10))
        }
        let entries = try database.writer.read { db in
            try ProgressRepository.entries(db, taskID: todo.id)
        }
        XCTAssertEqual(entries.count, 1, "two clocks on one task would double-count it")
        XCTAssertEqual(entries[0].startedAt, at(9), "the original start is kept")
    }

    func testStoppingOneTimerLeavesTheOthersRunning() throws {
        let first = try insert("Write the release notes")
        let second = try insert("Fix the flaky test")

        try database.writer.write { db in
            try ProgressRepository.startSession(db, taskID: first.id, at: at(9))
            try ProgressRepository.startSession(db, taskID: second.id, at: at(9, 30))
            try ProgressRepository.stopSession(db, taskID: first.id, at: at(11))
        }

        let running = try database.writer.read { db in try ProgressRepository.running(db) }
        XCTAssertEqual(running.map(\.taskID), [second.id])

        let stopped = try database.writer.read { db in
            try ProgressRepository.entries(db, taskID: first.id)
        }
        XCTAssertEqual(stopped.first?.minutes(), 120)
    }

    func testStopAllClosesEveryRunningSession() throws {
        let first = try insert("Write the release notes")
        let second = try insert("Fix the flaky test")

        try database.writer.write { db in
            try ProgressRepository.startSession(db, taskID: first.id, at: at(9))
            try ProgressRepository.startSession(db, taskID: second.id, at: at(9, 30))
            try ProgressRepository.stopAll(db, at: at(11))
        }

        try database.writer.read { db in
            XCTAssertTrue(try ProgressRepository.running(db).isEmpty)
            XCTAssertEqual(try ProgressRepository.entries(db, taskID: first.id).first?.minutes(), 120)
            XCTAssertEqual(try ProgressRepository.entries(db, taskID: second.id).first?.minutes(), 90)
        }
    }

    func testStartingATimerMarksTheTaskAsDoing() throws {
        let todo = try insert("Write the release notes")
        try database.writer.write { db in
            try ProgressRepository.startSession(db, taskID: todo.id, at: at(9))
        }
        try database.writer.read { db in
            XCTAssertEqual(try TodoRepository.fetch(db, id: todo.id)?.status, .doing)
        }
    }

    func testAnAccidentalStartLeavesNoTrace() throws {
        let todo = try insert("Write the release notes")
        try database.writer.write { db in
            try ProgressRepository.startSession(db, taskID: todo.id, at: at(9))
            try ProgressRepository.stopSession(db, taskID: todo.id, at: at(9, 0).addingTimeInterval(20))
        }
        try database.writer.read { db in
            XCTAssertTrue(try ProgressRepository.entries(db, taskID: todo.id).isEmpty)
        }
    }

    func testStoppingWithANoteKeepsItOnTheSession() throws {
        let todo = try insert("Write the release notes")
        try database.writer.write { db in
            try ProgressRepository.startSession(db, taskID: todo.id, at: at(9))
            try ProgressRepository.stopSession(db, taskID: todo.id, at: at(10, 30), note: "Drafted the breaking changes")
        }
        let entries = try database.writer.read { db in
            try ProgressRepository.entries(db, taskID: todo.id)
        }
        XCTAssertEqual(entries.count, 1, "the note joins the session rather than adding an entry")
        XCTAssertEqual(entries[0].note, "Drafted the breaking changes")
        XCTAssertEqual(entries[0].minutes(), 90)
    }

    // MARK: - Correcting what was recorded

    func testTimeCanBeLoggedForAnyPastDay() throws {
        let todo = try insert("Write the release notes")
        try database.writer.write { db in
            try ProgressRepository.addSession(
                db, taskID: todo.id,
                from: at(14, day: 3), to: at(16, day: 3),
                note: "Sat down with the outline"
            )
        }
        let entries = try database.writer.read { db in
            try ProgressRepository.entries(db, taskID: todo.id)
        }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].startedAt, at(14, day: 3), "logged where it happened, not today")
        XCTAssertEqual(entries[0].minutes(), 120)
        XCTAssertEqual(entries[0].note, "Sat down with the outline")
    }

    func testAnEntrysTimesCanBeCorrectedAfterTheFact() throws {
        let todo = try insert("Write the release notes")
        try database.writer.write { db in
            try ProgressRepository.startSession(db, taskID: todo.id, at: at(9))
            try ProgressRepository.stopSession(db, taskID: todo.id, at: at(17))
        }

        // The classic: left running through lunch, so eight hours got recorded
        // where two were worked.
        var entry = try XCTUnwrap(
            try database.writer.read { db in try ProgressRepository.entries(db, taskID: todo.id).first }
        )
        XCTAssertEqual(entry.minutes(), 480)

        entry.startedAt = at(9)
        entry.endedAt = at(11)
        try database.writer.write { db in try ProgressRepository.update(db, entry) }

        let corrected = try database.writer.read { db in
            try ProgressRepository.summaries(db, taskIDs: [todo.id])[todo.id]
        }
        XCTAssertEqual(corrected?.trackedSeconds, 7200)
    }

    func testCorrectingASessionOntoAnotherDayMovesItOnTheGrid() throws {
        let todo = try insert("Write the release notes")
        try database.writer.write { db in
            try ProgressRepository.addSession(db, taskID: todo.id, from: at(9), to: at(10))
        }
        var entry = try XCTUnwrap(
            try database.writer.read { db in try ProgressRepository.entries(db, taskID: todo.id).first }
        )
        entry.startedAt = at(9, day: 10)
        entry.endedAt = at(10, day: 10)
        try database.writer.write { db in try ProgressRepository.update(db, entry) }

        let onTheTwelfth = try database.writer.read { db in
            try ProgressRepository.sessions(
                db,
                in: DateInterval(start: at(0), end: at(0, day: 13))
            )
        }
        XCTAssertTrue(onTheTwelfth.isEmpty, "it left the day it was recorded on")

        let onTheTenth = try database.writer.read { db in
            try ProgressRepository.sessions(
                db,
                in: DateInterval(start: at(0, day: 10), end: at(0, day: 11))
            )
        }
        XCTAssertEqual(onTheTenth.count, 1)
    }

    // MARK: - Summaries

    func testSummaryCountsFinishedSessionsAndTracksTheRunningOne() throws {
        let todo = try insert("Write the release notes")
        try database.writer.write { db in
            try ProgressRepository.addSession(db, taskID: todo.id, from: at(9), to: at(10))
            try ProgressRepository.addNote(db, taskID: todo.id, text: "Blocked on the API", at: at(11))
            try ProgressRepository.startSession(db, taskID: todo.id, at: at(14))
        }

        let summary = try database.writer.read { db in
            try ProgressRepository.summaries(db, taskIDs: [todo.id])[todo.id]
        }
        let unwrapped = try XCTUnwrap(summary)
        XCTAssertEqual(unwrapped.trackedSeconds, 3600, "the running session is not banked yet")
        XCTAssertEqual(unwrapped.entryCount, 3)
        XCTAssertEqual(unwrapped.runningSince, at(14))
        XCTAssertEqual(unwrapped.lastAt, at(14))
        XCTAssertEqual(
            unwrapped.trackedMinutes(now: at(15)),
            120,
            "the running hour counts towards the readout without being written"
        )
    }

    func testARowCarriesItsOwnProgress() throws {
        let todo = try insert("Write the release notes")
        try database.writer.write { db in
            try ProgressRepository.addSession(db, taskID: todo.id, from: at(9), to: at(9, 45))
        }
        let rows = try database.writer.read { db in
            try TodoRepository.fetchDetails(
                db,
                query: TodoQuery(selection: .smart(.anytime)),
                now: at(12),
                calendar: calendar
            )
        }
        XCTAssertEqual(rows.first?.progress.trackedMinutes(now: at(12)), 45)
    }

    // MARK: - The grid

    func testSessionsInRangeIncludeTheRunningOne() throws {
        let todo = try insert("Write the release notes")
        try database.writer.write { db in
            try ProgressRepository.addSession(db, taskID: todo.id, from: at(9), to: at(10))
            try ProgressRepository.addSession(db, taskID: todo.id, from: at(9, day: 1), to: at(10, day: 1))
            try ProgressRepository.startSession(db, taskID: todo.id, at: at(14))
        }
        let range = DateInterval(start: at(0), end: at(0, day: 13))
        let sessions = try database.writer.read { db in
            try ProgressRepository.sessions(db, in: range)
        }
        XCTAssertEqual(sessions.count, 2, "the session on another day stays out of range")
        XCTAssertTrue(sessions.contains { $0.entry.isRunning })
        XCTAssertEqual(sessions.first?.todo.title, "Write the release notes")
    }

    func testRecordedTimeSharesTheColumnWithThePlanItOverlaps() throws {
        let todo = try insert("Write the release notes")
        let block = ScheduledBlock(
            block: TimeBlock(taskID: todo.id, startAt: at(9), endAt: at(10)),
            todo: todo
        )
        let session = TrackedSession(
            entry: ProgressEntry(
                taskID: todo.id, kind: .session, startedAt: at(9, 15), endedAt: at(10, 40)
            ),
            todo: todo
        )

        let positioned = CalendarLayout.position(
            [GridEntry(planned: block), try XCTUnwrap(GridEntry(tracked: session, now: at(12)))],
            days: [at(0)],
            calendar: calendar
        )

        XCTAssertEqual(positioned.count, 2)
        XCTAssertEqual(Set(positioned.map(\.column)), [0, 1], "they sit side by side")
        XCTAssertEqual(
            positioned.map(\.columnCount),
            [2, 2],
            "sharing one width, so plan and record line up against each other"
        )
    }

    func testRecordedTimeOnAFreeHourKeepsTheWholeColumn() throws {
        let todo = try insert("Write the release notes")
        let session = TrackedSession(
            entry: ProgressEntry(
                taskID: todo.id, kind: .session, startedAt: at(14), endedAt: at(15)
            ),
            todo: todo
        )
        let positioned = CalendarLayout.position(
            [try XCTUnwrap(GridEntry(tracked: session, now: at(16)))],
            days: [at(0)],
            calendar: calendar
        )
        XCTAssertEqual(positioned.first?.columnCount, 1)
        XCTAssertEqual(positioned.first?.span, 1)
    }

    func testOverlappingSessionsShareTheLaneInsteadOfCoveringEachOther() {
        let intervals = [
            DateInterval(start: at(9), end: at(11)),      // overlaps the next
            DateInterval(start: at(10), end: at(12)),
            DateInterval(start: at(14), end: at(15))      // on its own
        ]
        let packed = CalendarLayout.pack(intervals) { $0 }

        func placement(of interval: DateInterval) -> (column: Int, columnCount: Int)? {
            packed.first { $0.item == interval }.map { ($0.column, $0.columnCount) }
        }

        XCTAssertEqual(placement(of: intervals[0])?.column, 0)
        XCTAssertEqual(placement(of: intervals[1])?.column, 1, "the overlapping one moves aside")
        XCTAssertEqual(placement(of: intervals[0])?.columnCount, 2)
        XCTAssertEqual(placement(of: intervals[1])?.columnCount, 2)
        XCTAssertEqual(placement(of: intervals[2])?.column, 0, "a session on its own gets the full lane")
        XCTAssertEqual(placement(of: intervals[2])?.columnCount, 1)
    }

    func testAFreeColumnIsReusedOnceItsSessionHasFinished() {
        let intervals = [
            DateInterval(start: at(9), end: at(10)),
            DateInterval(start: at(9, 30), end: at(11)),
            DateInterval(start: at(10), end: at(10, 30))   // starts as the first ends
        ]
        let packed = CalendarLayout.pack(intervals) { $0 }
        XCTAssertEqual(packed.first { $0.item == intervals[2] }?.column, 0)
        XCTAssertEqual(
            packed.map(\.columnCount),
            [2, 2, 2],
            "a cluster shares one width, so the bars line up"
        )
    }

    func testARunningSessionHasNoIntervalUntilTimePasses() throws {
        let entry = ProgressEntry(taskID: "x", kind: .session, startedAt: at(9), endedAt: nil)
        XCTAssertNil(entry.interval(now: at(9)), "a zero-length bar would draw as a smear")
        XCTAssertEqual(entry.interval(now: at(10))?.duration, 3600)
    }

    // MARK: - Undo

    func testDeletingATaskAndUndoingItBringsBackTheTimeline() throws {
        let todo = try insert("Write the release notes")
        try database.writer.write { db in
            try ProgressRepository.addSession(db, taskID: todo.id, from: at(9), to: at(10))
            try ProgressRepository.addNote(db, taskID: todo.id, text: "Blocked on the API", at: at(11))
        }

        let snapshot = try database.writer.read { db in
            try TodoSnapshot.capture(db, ids: [todo.id])
        }
        try database.writer.write { db in try TodoRepository.delete(db, id: todo.id) }
        try database.writer.read { db in
            XCTAssertTrue(try ProgressRepository.entries(db, taskID: todo.id).isEmpty)
        }

        try database.writer.write { db in try TodoSnapshot.restore(db, snapshot) }
        let restored = try database.writer.read { db in
            try ProgressRepository.entries(db, taskID: todo.id)
        }
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.map(\.kind), [.note, .session], "newest first")
    }

    // MARK: - Notes preview

    func testNotesPreviewSkipsMarkdownFurniture() {
        var todo = Todo(title: "Ship it")
        todo.notes = "# Background\n\n- talked to the API team\n"
        let detail = TodoDetail(todo: todo)
        XCTAssertEqual(detail.notesPreview, "Background")

        todo.notes = "\n\n   \n* [ ] chase the signing key\n"
        XCTAssertEqual(TodoDetail(todo: todo).notesPreview, "chase the signing key")

        todo.notes = ""
        XCTAssertNil(TodoDetail(todo: todo).notesPreview)
    }

    func testDaysAgoReadsInWholeDays() {
        let now = at(9, day: 12)
        XCTAssertEqual(Format.daysAgo(at(23, day: 12), now: now, calendar: calendar), "today")
        XCTAssertEqual(Format.daysAgo(at(9, day: 11), now: now, calendar: calendar), "yesterday")
        XCTAssertEqual(Format.daysAgo(at(9, day: 5), now: now, calendar: calendar), "7d ago")
    }
}
