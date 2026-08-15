import XCTest
@testable import Cadence

final class AgendaTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-08-05 is a Wednesday; "now" is 10:00.
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute))!
    }

    private var now: Date { date(5, 10) }

    private func block(
        _ title: String,
        day: Int,
        from: Int,
        to: Int,
        status: TodoStatus = .todo
    ) -> ScheduledBlock {
        let todo = Todo(title: title, status: status)
        return ScheduledBlock(
            block: TimeBlock(taskID: todo.id, startAt: date(day, from), endAt: date(day, to)),
            todo: todo,
            project: nil
        )
    }

    private func allDay(_ title: String, day: Int, status: TodoStatus = .todo) -> TodoDetail {
        TodoDetail(todo: Todo(title: title, status: status, dueAt: date(day, 0)))
    }

    private func sections(
        _ blocks: [ScheduledBlock],
        _ untimed: [TodoDetail] = []
    ) -> [AgendaSection] {
        AgendaBuilder.sections(blocks: blocks, allDay: untimed, now: now, calendar: calendar)
    }

    // MARK: - Grouping

    func testGroupsIntoTodayTomorrowAndUpcoming() {
        // Today's block is deliberately still ahead of `now`: one that has
        // already ended belongs under Overdue, which is a different test.
        let result = sections([
            block("Later today", day: 5, from: 14, to: 15),
            block("Tomorrow", day: 6, from: 9, to: 10),
            block("Friday", day: 7, from: 9, to: 10)
        ])
        XCTAssertEqual(result.map(\.title), ["Today", "Tomorrow", "Upcoming"])
        XCTAssertEqual(result[2].items.map(\.todo.title), ["Friday"])
    }

    func testEmptyGroupsAreOmitted() {
        let result = sections([block("Only today", day: 5, from: 14, to: 15)])
        XCTAssertEqual(result.map(\.kind), [.today])
    }

    func testNothingScheduledProducesNoSections() {
        XCTAssertTrue(sections([]).isEmpty)
    }

    func testWorkLeftOverFromYesterdayIsListedAsOverdue() {
        // It used to be folded into Today with nothing marking it, so a block
        // from Monday read exactly like one from this morning.
        let result = sections([block("Missed", day: 4, from: 9, to: 10)])
        XCTAssertEqual(result.first?.kind, .overdue)
        XCTAssertEqual(result.first?.items.map(\.todo.title), ["Missed"])
    }

    func testOverdueLeadsTheListAndTodayKeepsWhatIsStillAhead() {
        let result = sections([
            block("Yesterday", day: 4, from: 9, to: 10),
            block("Ran out this morning", day: 5, from: 8, to: 9),
            block("Still ahead", day: 5, from: 14, to: 15)
        ])
        XCTAssertEqual(result.map(\.kind), [.overdue, .today])
        XCTAssertEqual(
            result[0].items.map(\.todo.title),
            ["Yesterday", "Ran out this morning"]
        )
        XCTAssertEqual(result[1].items.map(\.todo.title), ["Still ahead"])
    }

    func testWorkUnderwayRightNowIsNotOverdue() {
        // now is 10:00, so this block still has an hour to run.
        let result = sections([block("Running", day: 5, from: 9, to: 11)])
        XCTAssertEqual(result.map(\.kind), [.today])
    }

    func testAnAllDayTaskDueTodayIsNotYetOverdue() {
        // It has no moment to be late against until the day is over.
        let result = sections([], [allDay("Due today", day: 5)])
        XCTAssertEqual(result.map(\.kind), [.today])
    }

    func testAnAllDayTaskFromAnEarlierDayIsOverdue() {
        let result = sections([], [allDay("Due Monday", day: 3)])
        XCTAssertEqual(result.map(\.kind), [.overdue])
    }

    func testDaysLateCountsWholeDaysAndIsZeroForToday() {
        let items = AgendaBuilder.items(
            blocks: [
                block("Two days ago", day: 3, from: 9, to: 10),
                block("Earlier today", day: 5, from: 8, to: 9)
            ],
            allDay: [],
            calendar: calendar
        )
        XCTAssertEqual(items[0].daysLate(now, calendar: calendar), 2)
        XCTAssertEqual(items[1].daysLate(now, calendar: calendar), 0)
    }

    func testBeyondTheHorizonIsNotListed() {
        XCTAssertTrue(sections([block("Next month", day: 5 + 40, from: 9, to: 10)]).isEmpty)
    }

    func testCompletedWorkIsNotListed() {
        let result = sections(
            [block("Done", day: 5, from: 9, to: 10, status: .done)],
            [allDay("Also done", day: 5, status: .cancelled)]
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Ordering

    func testAllDayItemsLeadTheirDayThenEverythingInTimeOrder() {
        let result = sections(
            [
                block("Afternoon", day: 5, from: 14, to: 15),
                block("Late morning", day: 5, from: 11, to: 12)
            ],
            [allDay("Due today", day: 5)]
        )
        XCTAssertEqual(
            result[0].items.map(\.todo.title),
            ["Due today", "Late morning", "Afternoon"]
        )
    }

    func testAllDayItemsHaveNoInterval() {
        let result = sections([], [allDay("Due today", day: 5)])
        XCTAssertTrue(result[0].items[0].isAllDay)
        XCTAssertNil(result[0].items[0].interval)
    }

    // MARK: - What the header reports about today

    private func focus(
        _ blocks: [ScheduledBlock],
        _ untimed: [TodoDetail] = [],
        at moment: Date? = nil
    ) -> AgendaBuilder.Focus {
        AgendaBuilder.focus(
            in: AgendaBuilder.items(blocks: blocks, allDay: untimed, calendar: calendar),
            now: moment ?? now,
            calendar: calendar
        )
    }

    func testSomethingUnderwayWinsOverWhatIsNext() {
        let result = focus([
            block("Running now", day: 5, from: 9, to: 11),
            block("Later today", day: 5, from: 14, to: 15)
        ])
        guard case .underway(let item) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(item.todo.title, "Running now")
    }

    func testOtherwiseTheNextThingToday() {
        let result = focus([
            block("Finished", day: 5, from: 8, to: 9),
            block("Coming up", day: 5, from: 14, to: 15)
        ])
        guard case .next(let item) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(item.todo.title, "Coming up")
    }

    /// The bug this enum exists for: at 22:00 every block has been and gone,
    /// but the day is not empty and saying so was simply false.
    func testWorkWhoseTimeHasPassedIsReportedAsStillOpen() {
        let result = focus(
            [
                block("Morning", day: 5, from: 4, to: 6),
                block("Later morning", day: 5, from: 9, to: 10)
            ],
            at: date(5, 22)
        )
        guard case .overdue(let count) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(count, 2)
    }

    func testAnAllDayTaskCountsTowardsWhatIsStillOpen() {
        let result = focus([], [allDay("Due today", day: 5)], at: date(5, 22))
        guard case .overdue(let count) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(count, 1)
    }

    func testCompletedWorkIsNotReportedAsOpen() {
        // Completed items are filtered out of the agenda entirely, so a day
        // whose work is all done reads as empty rather than as done. Assert the
        // behaviour that actually reaches the header.
        let result = focus(
            [block("Done", day: 5, from: 9, to: 10, status: .done)],
            at: date(5, 22)
        )
        XCTAssertEqual(result, .empty)
    }

    func testAnEmptyDayIsReportedAsEmpty() {
        XCTAssertEqual(focus([block("Tomorrow", day: 6, from: 9, to: 10)]), .empty)
    }

    func testTomorrowIsNeverOfferedAsUpNext() {
        // "Up next: something 22 hours away" is noise, not information.
        XCTAssertEqual(focus([block("Tomorrow", day: 6, from: 9, to: 10)]), .empty)
    }

    func testAnAllDayItemIsNeverUpNext() {
        // It has no moment to count down to; before any timed work it is just
        // part of the day's open list.
        let result = focus([], [allDay("Due", day: 5)])
        guard case .overdue = result else { return XCTFail("got \(result)") }
    }

    // MARK: - What the status item counts

    @MainActor
    private func model(_ items: [AgendaItem]) throws -> AppModel {
        let model = AppModel(database: try AppDatabase.inMemory())
        model.agendaItems = items
        return model
    }

    private var yesterdayAndAhead: [AgendaItem] {
        AgendaBuilder.items(
            blocks: [
                block("Yesterday", day: 4, from: 9, to: 10),
                block("Still ahead", day: 5, from: 14, to: 15)
            ],
            allDay: [],
            calendar: calendar
        )
    }

    @MainActor
    func testTheBadgeCountsOverdueWhileTheSectionIsShown() throws {
        let model = try model(yesterdayAndAhead)
        XCTAssertEqual(
            model.todayRemainingCount(includingOverdue: true, now: now, calendar: calendar),
            2
        )
    }

    @MainActor
    func testCollapsingOverdueTakesItOutOfTheBadgeToo() throws {
        // Putting the section away has to put its number away, or the badge
        // goes on reporting exactly what you just chose not to look at.
        let model = try model(yesterdayAndAhead)
        XCTAssertEqual(
            model.todayRemainingCount(includingOverdue: false, now: now, calendar: calendar),
            1
        )
    }

    @MainActor
    func testTheBadgeEmptiesWhenEverythingLeftIsOverdueAndCollapsed() throws {
        let model = try model(
            AgendaBuilder.items(
                blocks: [block("Yesterday", day: 4, from: 9, to: 10)],
                allDay: [],
                calendar: calendar
            )
        )
        XCTAssertEqual(
            model.todayRemainingCount(includingOverdue: false, now: now, calendar: calendar),
            0
        )
    }

    func testPassedAndUnderwayFlags() {
        let items = AgendaBuilder.items(
            blocks: [
                block("Over", day: 5, from: 8, to: 9),
                block("Running", day: 5, from: 9, to: 11)
            ],
            allDay: [],
            calendar: calendar
        )
        XCTAssertTrue(items[0].hasPassed(now))
        XCTAssertFalse(items[0].isUnderway(now))
        XCTAssertTrue(items[1].isUnderway(now))
        XCTAssertFalse(items[1].hasPassed(now))
    }
}
