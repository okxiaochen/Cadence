import XCTest
@testable import Cadence

final class CalendarTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-08-05 is a Wednesday.
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute))!
    }

    private func interval(_ day: Int, _ from: Int, _ to: Int) -> DateInterval {
        DateInterval(start: date(day, from), end: date(day, to))
    }

    // MARK: - FreeBusy

    func testMergeCollapsesOverlappingAndTouchingIntervals() {
        let merged = FreeBusy.merge([
            interval(5, 9, 11),
            interval(5, 10, 12),   // overlaps
            interval(5, 12, 13),   // touches
            interval(5, 15, 16)    // separate
        ])
        XCTAssertEqual(merged, [interval(5, 9, 13), interval(5, 15, 16)])
    }

    func testMergeDropsZeroLengthIntervals() {
        XCTAssertTrue(FreeBusy.merge([DateInterval(start: date(5, 9), end: date(5, 9))]).isEmpty)
    }

    func testGapsAroundBusyTime() {
        let free = FreeBusy.gaps(
            in: interval(5, 9, 18),
            busy: [interval(5, 10, 11), interval(5, 14, 15)]
        )
        XCTAssertEqual(free, [interval(5, 9, 10), interval(5, 11, 14), interval(5, 15, 18)])
    }

    func testGapsWhenBusyCoversTheWholeWindow() {
        XCTAssertTrue(FreeBusy.gaps(in: interval(5, 9, 18), busy: [interval(5, 8, 20)]).isEmpty)
    }

    func testGapsIgnoreBusyTimeOutsideTheWindow() {
        let free = FreeBusy.gaps(in: interval(5, 9, 12), busy: [interval(5, 6, 8), interval(5, 13, 14)])
        XCTAssertEqual(free, [interval(5, 9, 12)])
    }

    func testOpeningsRespectMinimumDuration() {
        let openings = FreeBusy.openings(
            in: [interval(5, 9, 18)],
            busy: [interval(5, 10, 11), interval(5, 11, 14)],
            minimumMinutes: 90
        )
        // 9–10 is only 60 minutes, so just 14–18 survives.
        XCTAssertEqual(openings, [interval(5, 14, 18)])
    }

    func testTouchingIntervalsDoNotCountAsOverlapping() {
        XCTAssertFalse(interval(5, 9, 10).overlaps(interval(5, 10, 11)))
        XCTAssertTrue(interval(5, 9, 11).overlaps(interval(5, 10, 12)))
    }

    // MARK: - Snapping

    func testSnapRoundsToNearestBoundary() {
        XCTAssertEqual(
            CalendarLayout.snap(date(5, 9, 7), to: 15, calendar: calendar),
            date(5, 9, 0)
        )
        XCTAssertEqual(
            CalendarLayout.snap(date(5, 9, 8), to: 15, calendar: calendar),
            date(5, 9, 15)
        )
        XCTAssertEqual(
            CalendarLayout.snap(date(5, 9, 38), to: 30, calendar: calendar),
            date(5, 9, 30)
        )
    }

    // MARK: - Scales

    func testWeekScaleStartsOnMonday() {
        // Anchored on Wednesday the 5th, the week runs Mon 3rd – Sun 9th.
        let days = CalendarScale.week.days(anchoredAt: date(5, 12), calendar: calendar)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(calendar.component(.day, from: days[0]), 3)
        XCTAssertEqual(calendar.component(.day, from: days[6]), 9)
    }

    func testThreeDayScaleStartsAtTheAnchor() {
        let days = CalendarScale.threeDay.days(anchoredAt: date(5, 12), calendar: calendar)
        XCTAssertEqual(days.map { calendar.component(.day, from: $0) }, [5, 6, 7])
    }

    // MARK: - Overlap packing

    private func scheduled(_ title: String, _ day: Int, _ from: Int, _ to: Int) -> ScheduledBlock {
        let todo = Todo(title: title)
        return ScheduledBlock(
            block: TimeBlock(taskID: todo.id, startAt: date(day, from), endAt: date(day, to)),
            todo: todo,
            project: nil
        )
    }

    func testNonOverlappingBlocksEachTakeTheFullWidth() {
        let positioned = CalendarLayout.position(
            [scheduled("A", 5, 9, 10), scheduled("B", 5, 11, 12)],
            days: [date(5, 0)],
            calendar: calendar
        )
        XCTAssertEqual(positioned.count, 2)
        XCTAssertTrue(positioned.allSatisfy { $0.columnCount == 1 && $0.column == 0 })
    }

    func testOverlappingBlocksSplitIntoColumns() {
        let positioned = CalendarLayout.position(
            [scheduled("A", 5, 9, 11), scheduled("B", 5, 10, 12)],
            days: [date(5, 0)],
            calendar: calendar
        )
        XCTAssertEqual(Set(positioned.map(\.columnCount)), [2])
        XCTAssertEqual(Set(positioned.map(\.column)), [0, 1])
    }

    func testTransitiveOverlapFormsOneCluster() {
        // A overlaps B, B overlaps C, but A and C do not touch. All three still
        // share a cluster so their widths line up.
        let positioned = CalendarLayout.position(
            [scheduled("A", 5, 9, 11), scheduled("B", 5, 10, 13), scheduled("C", 5, 12, 14)],
            days: [date(5, 0)],
            calendar: calendar
        )
        XCTAssertEqual(Set(positioned.map(\.columnCount)), [2])
        // C can reuse A's column because A has finished by then.
        let byTitle = Dictionary(uniqueKeysWithValues: positioned.map { ($0.block.todo.title, $0.column) })
        XCTAssertEqual(byTitle["A"], 0)
        XCTAssertEqual(byTitle["B"], 1)
        XCTAssertEqual(byTitle["C"], 0)
    }

    func testBlocksAreAssignedToTheRightDayColumn() {
        let positioned = CalendarLayout.position(
            [scheduled("Wed", 5, 9, 10), scheduled("Fri", 7, 9, 10)],
            days: [date(5, 0), date(6, 0), date(7, 0)],
            calendar: calendar
        )
        let byTitle = Dictionary(uniqueKeysWithValues: positioned.map { ($0.block.todo.title, $0.dayIndex) })
        XCTAssertEqual(byTitle["Wed"], 0)
        XCTAssertEqual(byTitle["Fri"], 2)
    }

    func testBlocksOutsideTheVisibleDaysAreDropped() {
        let positioned = CalendarLayout.position(
            [scheduled("Elsewhere", 20, 9, 10)],
            days: [date(5, 0)],
            calendar: calendar
        )
        XCTAssertTrue(positioned.isEmpty)
    }

    // MARK: - Geometry

    private var geometry: CalendarGeometry {
        CalendarGeometry(
            days: [date(5, 0), date(6, 0), date(7, 0)],
            dayWidth: 100,
            hourHeight: 60,
            calendar: calendar
        )
    }

    func testTimeMapsToVerticalOffset() {
        XCTAssertEqual(geometry.y(for: date(5, 9, 30)), 570)      // 9.5h × 60
        // 2h × 60, less the 1pt gap that keeps back-to-back blocks apart.
        XCTAssertEqual(geometry.height(for: interval(5, 9, 11)), 120 - CalendarGeometry.blockGap)
    }

    func testPointMapsBackToASnappedDate() {
        // x = 150 lands in the second day column (100pt each).
        // y = 572 at 60pt/hour is 9:32, whose nearest 15-minute mark is 9:30…
        XCTAssertEqual(geometry.date(at: CGPoint(x: 150, y: 572), snapMinutes: 15), date(6, 9, 30))
        // …while 9:38 rounds up to 9:45.
        XCTAssertEqual(geometry.date(at: CGPoint(x: 150, y: 578), snapMinutes: 15), date(6, 9, 45))
    }

    func testPointBeyondTheLastColumnClampsToIt() {
        let result = geometry.date(at: CGPoint(x: 9_999, y: 60), snapMinutes: 15)
        XCTAssertEqual(result, date(7, 1))
    }

    func testNegativeYClampsToMidnight() {
        let result = geometry.date(at: CGPoint(x: 10, y: -400), snapMinutes: 15)
        XCTAssertEqual(result, date(5, 0))
    }

    func testRepositionKeepsDurationAndStaysInsideTheDay() {
        let original = interval(5, 9, 11)

        let moved = geometry.reposition(original, toStart: date(6, 14))
        XCTAssertEqual(moved, interval(6, 14, 16))

        // Dropping a two-hour block at 23:00 pins it to 22:00–24:00.
        let clamped = geometry.reposition(original, toStart: date(6, 23))
        XCTAssertEqual(clamped.duration, original.duration)
        XCTAssertEqual(clamped.end, calendar.startOfDay(for: date(7, 0)))
    }

    func testOverlapColumnsProduceSideBySideRects() {
        let left = geometry.rect(interval: interval(5, 9, 10), dayIndex: 0, column: 0, columnCount: 2)
        let right = geometry.rect(interval: interval(5, 9, 10), dayIndex: 0, column: 1, columnCount: 2)
        XCTAssertLessThan(left.minX, right.minX)
        XCTAssertEqual(left.width, right.width)
        XCTAssertLessThanOrEqual(right.maxX, geometry.dayWidth)
    }

    // MARK: - Working hours

    @MainActor
    func testWorkingHoursSkipWeekendsUnlessEnabled() {
        let preferences = Preferences(defaults: UserDefaults(suiteName: "CadenceTests-\(UUID())")!)
        preferences.workdayStartHour = 9
        preferences.workdayEndHour = 18

        let wednesday = date(5, 12)
        let saturday = date(8, 12)

        XCTAssertEqual(preferences.workingHours(on: wednesday, calendar: calendar), interval(5, 9, 18))
        XCTAssertNil(preferences.workingHours(on: saturday, calendar: calendar))

        preferences.includesWeekends = true
        XCTAssertEqual(preferences.workingHours(on: saturday, calendar: calendar), interval(8, 9, 18))
    }

    @MainActor
    func testHourHeightIsClampedToUsableZoom() {
        let preferences = Preferences(defaults: UserDefaults(suiteName: "CadenceTests-\(UUID())")!)
        preferences.hourHeight = 5_000
        XCTAssertEqual(preferences.hourHeight, 200)
        preferences.hourHeight = 1
        XCTAssertEqual(preferences.hourHeight, 24)
    }

    // MARK: - Resizing

    func testResizeEdgeIgnoresHorizontalDrift() {
        // Dragging an edge sideways must keep it on the block's own day,
        // otherwise a block would end on a different day than it starts.
        let day = date(5, 0)
        let onDay = geometry.date(onDay: day, atY: 630, snapMinutes: 15)
        XCTAssertEqual(onDay, date(5, 10, 30))

        // The same y through the x-aware lookup lands on whichever column x hits.
        XCTAssertEqual(geometry.date(at: CGPoint(x: 250, y: 630), snapMinutes: 15), date(7, 10, 30))
    }

    func testResizeEdgeClampsToTheDay() {
        let day = date(5, 0)
        XCTAssertEqual(geometry.date(onDay: day, atY: -500, snapMinutes: 15), date(5, 0))
        XCTAssertEqual(
            geometry.date(onDay: day, atY: 99_999, snapMinutes: 15),
            calendar.startOfDay(for: date(6, 0))
        )
    }

    // MARK: - Adjacent blocks must not collide

    func testBackToBackBlocksDoNotOverlapOnScreen() {
        // 9–11 and 11–12 share an instant but not an interval; their rects
        // must not, or they read as one merged box.
        let first = geometry.rect(interval: interval(5, 9, 11), dayIndex: 0, column: 0, columnCount: 1)
        let second = geometry.rect(interval: interval(5, 11, 12), dayIndex: 0, column: 0, columnCount: 1)

        XCTAssertLessThanOrEqual(first.maxY, second.minY, "adjacent blocks overlap")
        XCTAssertGreaterThan(second.minY - first.maxY, 0, "adjacent blocks share an edge")
    }

    func testShortBlocksDoNotSpillOverTheNextOne() {
        // The old 14pt minimum height made a 15-minute block taller than its
        // slot, so it covered whatever came next.
        let tight = CalendarGeometry(days: [date(5, 0)], dayWidth: 100, hourHeight: 30, calendar: calendar)
        let first = tight.rect(
            interval: DateInterval(start: date(5, 9), duration: 900),
            dayIndex: 0, column: 0, columnCount: 1
        )
        let second = tight.rect(
            interval: DateInterval(start: date(5, 9, 15), duration: 900),
            dayIndex: 0, column: 0, columnCount: 1
        )
        XCTAssertLessThanOrEqual(first.maxY, second.minY)
    }

    func testBackToBackBlocksSitInTheSameColumn() {
        let positioned = CalendarLayout.position(
            [scheduled("A", 5, 9, 11), scheduled("B", 5, 11, 12)],
            days: [date(5, 0)],
            calendar: calendar
        )
        XCTAssertTrue(positioned.allSatisfy { $0.column == 0 && $0.columnCount == 1 })
    }

    // MARK: - Width expansion

    func testABlockWidensWhenNothingOverlapsItToTheRight() {
        // Three columns: A spans the morning, B and C sit beside it, then D
        // reuses B's column after B has finished. Nothing remains in column 2
        // during D's window, so D should widen into it rather than leave a gap.
        let positioned = CalendarLayout.position(
            [
                scheduled("A", 5, 9, 12),
                scheduled("B", 5, 9, 10),
                scheduled("C", 5, 9, 10),
                ScheduledBlock(
                    block: TimeBlock(taskID: "d", startAt: date(5, 10, 30), endAt: date(5, 11)),
                    todo: Todo(id: "d", title: "D"), project: nil
                )
            ],
            days: [date(5, 0)],
            calendar: calendar
        )
        let byTitle = Dictionary(uniqueKeysWithValues: positioned.map { ($0.block.todo.title, $0) })

        XCTAssertEqual(byTitle["A"]?.columnCount, 3)
        XCTAssertEqual(byTitle["A"]?.span, 1, "A overlaps both neighbours, so it stays narrow")
        XCTAssertEqual(byTitle["D"]?.span, 2, "nothing overlaps D to its right")
    }

    func testSpanWidensTheRect() {
        let narrow = geometry.rect(interval: interval(5, 9, 10), dayIndex: 0, column: 0, columnCount: 2, span: 1)
        let wide = geometry.rect(interval: interval(5, 9, 10), dayIndex: 0, column: 0, columnCount: 2, span: 2)
        XCTAssertGreaterThan(wide.width, narrow.width)
        XCTAssertEqual(wide.minX, narrow.minX)
    }
}
