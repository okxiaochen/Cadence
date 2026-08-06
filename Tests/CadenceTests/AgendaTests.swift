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
        let result = sections([
            block("This morning", day: 5, from: 9, to: 10),
            block("Tomorrow", day: 6, from: 9, to: 10),
            block("Friday", day: 7, from: 9, to: 10)
        ])
        XCTAssertEqual(result.map(\.title), ["Today", "Tomorrow", "Upcoming"])
        XCTAssertEqual(result[2].items.map(\.todo.title), ["Friday"])
    }

    func testEmptyGroupsAreOmitted() {
        let result = sections([block("Only today", day: 5, from: 9, to: 10)])
        XCTAssertEqual(result.map(\.kind), [.today])
    }

    func testNothingScheduledProducesNoSections() {
        XCTAssertTrue(sections([]).isEmpty)
    }

    func testWorkLeftOverFromYesterdayShowsWithToday() {
        // Otherwise it lands in no section at all and quietly disappears.
        let result = sections([block("Missed", day: 4, from: 9, to: 10)])
        XCTAssertEqual(result.first?.kind, .today)
        XCTAssertEqual(result.first?.items.map(\.todo.title), ["Missed"])
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
                block("Morning", day: 5, from: 9, to: 10)
            ],
            [allDay("Due today", day: 5)]
        )
        XCTAssertEqual(
            result[0].items.map(\.todo.title),
            ["Due today", "Morning", "Afternoon"]
        )
    }

    func testAllDayItemsHaveNoInterval() {
        let result = sections([], [allDay("Due today", day: 5)])
        XCTAssertTrue(result[0].items[0].isAllDay)
        XCTAssertNil(result[0].items[0].interval)
    }

    // MARK: - What the status item highlights

    func testSomethingUnderwayWinsOverWhatIsNext() {
        let items = AgendaBuilder.items(
            blocks: [
                block("Running now", day: 5, from: 9, to: 11),
                block("Later today", day: 5, from: 14, to: 15)
            ],
            allDay: [],
            calendar: calendar
        )
        XCTAssertEqual(
            AgendaBuilder.focus(in: items, now: now, calendar: calendar)?.todo.title,
            "Running now"
        )
    }

    func testOtherwiseTheNextThingToday() {
        let items = AgendaBuilder.items(
            blocks: [
                block("Finished", day: 5, from: 8, to: 9),
                block("Coming up", day: 5, from: 14, to: 15)
            ],
            allDay: [],
            calendar: calendar
        )
        XCTAssertEqual(
            AgendaBuilder.focus(in: items, now: now, calendar: calendar)?.todo.title,
            "Coming up"
        )
    }

    func testTomorrowIsNotOfferedAsUpNext() {
        // "Up next: something 22 hours away" is noise, not information.
        let items = AgendaBuilder.items(
            blocks: [block("Tomorrow", day: 6, from: 9, to: 10)],
            allDay: [],
            calendar: calendar
        )
        XCTAssertNil(AgendaBuilder.focus(in: items, now: now, calendar: calendar))
    }

    func testAnAllDayItemIsNeverUpNext() {
        let items = AgendaBuilder.items(blocks: [], allDay: [allDay("Due", day: 5)], calendar: calendar)
        XCTAssertNil(AgendaBuilder.focus(in: items, now: now, calendar: calendar))
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
