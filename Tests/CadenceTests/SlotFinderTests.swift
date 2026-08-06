import XCTest
@testable import Cadence

/// `find_free_slots` is the linchpin of the AI layer: the model picks among
/// these, it never computes availability itself. So it gets tested hard.
final class SlotFinderTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-08-05 is a Wednesday; the 8th and 9th are the weekend.
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute))!
    }

    private func interval(_ day: Int, _ from: Int, _ to: Int) -> DateInterval {
        DateInterval(start: date(day, from), end: date(day, to))
    }

    /// 9–18 on weekdays, nothing at the weekend.
    private func workdays(_ day: Date) -> DateInterval? {
        let weekday = calendar.component(.weekday, from: day)
        guard weekday != 1, weekday != 7 else { return nil }
        let start = calendar.startOfDay(for: day)
        return DateInterval(
            start: calendar.date(byAdding: .hour, value: 9, to: start)!,
            end: calendar.date(byAdding: .hour, value: 18, to: start)!
        )
    }

    private func find(
        minutes: Int,
        from: Date,
        to: Date,
        busy: [DateInterval] = [],
        withinWorkingHours: Bool = true,
        buffer: Int = 0,
        notBefore: Date? = nil,
        notAfter: Date? = nil,
        limit: Int = 8
    ) -> [SlotCandidate] {
        SlotFinder.find(
            constraints: SlotConstraints(
                durationMinutes: minutes,
                range: DateInterval(start: from, end: to),
                withinWorkingHours: withinWorkingHours,
                bufferMinutes: buffer,
                notBefore: notBefore,
                notAfter: notAfter,
                limit: limit
            ),
            busy: busy,
            workingHours: workdays,
            calendar: calendar
        )
    }

    // MARK: - Basics

    func testEveryProposedSlotHasTheRequestedDuration() {
        let slots = find(minutes: 45, from: date(5, 0), to: date(6, 0))
        XCTAssertFalse(slots.isEmpty)
        for slot in slots {
            XCTAssertEqual(slot.interval.duration, 45 * 60)
        }
    }

    func testSlotsNeverOverlapBusyTime() {
        let busy = [interval(5, 10, 12), interval(5, 14, 15)]
        let slots = find(minutes: 60, from: date(5, 0), to: date(6, 0), busy: busy)

        XCTAssertFalse(slots.isEmpty)
        for slot in slots {
            for taken in busy {
                XCTAssertFalse(
                    slot.interval.overlaps(taken),
                    "\(slot.start) collides with \(taken)"
                )
            }
        }
    }

    func testSlotsStayInsideWorkingHours() {
        let slots = find(minutes: 60, from: date(5, 0), to: date(6, 0))
        for slot in slots {
            XCTAssertGreaterThanOrEqual(slot.start, date(5, 9))
            XCTAssertLessThanOrEqual(slot.end, date(5, 18))
        }
    }

    func testWeekendsAreSkippedUnlessWorkingHoursAreIgnored() {
        // Saturday the 8th only.
        XCTAssertTrue(find(minutes: 60, from: date(8, 0), to: date(9, 0)).isEmpty)

        let anytime = find(minutes: 60, from: date(8, 0), to: date(9, 0), withinWorkingHours: false)
        XCTAssertFalse(anytime.isEmpty)
    }

    func testNoSlotsWhenTheDayIsFull() {
        let slots = find(minutes: 60, from: date(5, 0), to: date(6, 0), busy: [interval(5, 0, 24)])
        XCTAssertTrue(slots.isEmpty)
    }

    func testNoSlotsWhenNothingIsLongEnough() {
        // Two 30-minute holes, and a 60-minute task.
        let busy = [interval(5, 9, 12), interval(5, 12, 17)]  // leaves 12:00 nothing, 17–18 only
        let slots = find(minutes: 120, from: date(5, 0), to: date(6, 0), busy: busy)
        XCTAssertTrue(slots.isEmpty)
    }

    // MARK: - Ranking

    func testEarlierSlotsRankFirst() {
        let slots = find(minutes: 30, from: date(5, 0), to: date(8, 0))
        XCTAssertFalse(slots.isEmpty)
        XCTAssertEqual(slots[0].start, date(5, 9))

        let starts = slots.map(\.start)
        XCTAssertEqual(starts, starts.sorted(), "candidates should be offered earliest-first")
    }

    func testAnExactFitIsOfferedAndLabelled() {
        // Wednesday has a wide-open afternoon; Thursday has a precise 60-minute
        // hole. Ordering stays earliest-first, but the exact fit is surfaced
        // among the candidates and says why it is a good choice.
        let busy = [
            interval(5, 9, 10),
            interval(6, 9, 13), interval(6, 14, 18)   // exactly 13:00–14:00 free
        ]
        let slots = find(minutes: 60, from: date(5, 0), to: date(7, 0), busy: busy)
        let exact = slots.first { $0.start == date(6, 13) }
        XCTAssertNotNil(exact)
        XCTAssertTrue(exact?.reasons.contains("fills the gap exactly") ?? false)
    }

    func testLimitIsRespected() {
        XCTAssertLessThanOrEqual(find(minutes: 30, from: date(5, 0), to: date(8, 0), limit: 3).count, 3)
    }

    // MARK: - Constraints

    func testBufferKeepsSlotsAwayFromExistingCommitments() {
        let busy = [interval(5, 10, 11)]
        let slots = find(minutes: 30, from: date(5, 0), to: date(6, 0), busy: busy, buffer: 15)

        for slot in slots {
            XCTAssertFalse(slot.interval.overlaps(
                DateInterval(start: date(5, 9, 45), end: date(5, 11, 15))
            ))
        }
    }

    func testNotBeforeTrimsTheStartOfTheWindow() {
        let slots = find(minutes: 60, from: date(5, 0), to: date(6, 0), notBefore: date(5, 14))
        XCTAssertFalse(slots.isEmpty)
        for slot in slots {
            XCTAssertGreaterThanOrEqual(slot.start, date(5, 14))
        }
    }

    func testNotAfterTrimsTheEndOfTheWindow() {
        let slots = find(minutes: 60, from: date(5, 0), to: date(6, 0), notAfter: date(5, 12))
        XCTAssertFalse(slots.isEmpty)
        for slot in slots {
            XCTAssertLessThanOrEqual(slot.end, date(5, 12))
        }
    }

    func testImpossibleConstraintsYieldNothingRatherThanSomethingWrong() {
        let slots = find(
            minutes: 120,
            from: date(5, 0),
            to: date(6, 0),
            notBefore: date(5, 16),
            notAfter: date(5, 17)
        )
        XCTAssertTrue(slots.isEmpty)
    }

    func testStartsLandOnTheSnapGrid() {
        let busy = [interval(5, 9, 10)]   // free from 10:00
        let slots = find(minutes: 30, from: date(5, 0), to: date(6, 0), busy: busy)
        for slot in slots {
            let minute = calendar.component(.minute, from: slot.start)
            XCTAssertEqual(minute % 15, 0, "start \(slot.start) is off the 15-minute grid")
        }
    }

    func testSearchIsBoundedByTheRequestedRange() {
        let slots = find(minutes: 30, from: date(5, 11), to: date(5, 13))
        XCTAssertFalse(slots.isEmpty)
        for slot in slots {
            XCTAssertGreaterThanOrEqual(slot.start, date(5, 11))
            XCTAssertLessThanOrEqual(slot.end, date(5, 13))
        }
    }
}
