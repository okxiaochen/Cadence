import XCTest
@testable import Cadence

/// What the companion decides to say, and when it decides to stay quiet.
///
/// The quiet half matters more. A companion that comments on an ordinary
/// afternoon is one people switch off within a day, and switching it off is a
/// decision nobody reverses.
final class PetTests: XCTestCase {

    private func item(_ title: String, at hour: Int) -> AgendaItem {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 17, hour: hour
        ))!
        return AgendaItem(
            todo: Todo(title: title),
            interval: DateInterval(start: start, duration: 3600),
            day: calendar.startOfDay(for: start)
        )
    }

    private func status(
        openToday: Int = 0,
        focus: AgendaBuilder.Focus = .empty,
        nextEvent: PetStatus.Event? = nil,
        timingMinutes: Int? = nil,
        breakAdvice: BreakAdvice = .none
    ) -> PetStatus {
        PetStatus(
            openToday: openToday, focus: focus, nextEvent: nextEvent,
            timingMinutes: timingMinutes, breakAdvice: breakAdvice
        )
    }

    // MARK: - When a break is worth mentioning

    func testNothingRunningMeansNothingToInterrupt() {
        XCTAssertEqual(
            BreakAdvice.decide(timingSeconds: nil, after: 50, lastSuggestedAt: nil),
            .none
        )
    }

    func testUnderTheThresholdSaysNothing() {
        XCTAssertEqual(
            BreakAdvice.decide(timingSeconds: 49 * 60, after: 50, lastSuggestedAt: nil),
            .none
        )
    }

    func testPastTheThresholdSaysSo() {
        XCTAssertEqual(
            BreakAdvice.decide(timingSeconds: 52 * 60, after: 50, lastSuggestedAt: nil),
            .due(workedMinutes: 52)
        )
    }

    /// Without this it would say the same thing every minute for as long as the
    /// clock ran, which is the behaviour that gets a thing uninstalled.
    func testItDoesNotRepeatItselfInsideTheCooldown() {
        let now = Date()
        XCTAssertEqual(
            BreakAdvice.decide(
                timingSeconds: 90 * 60, after: 50,
                lastSuggestedAt: now.addingTimeInterval(-5 * 60), now: now
            ),
            .none
        )
    }

    func testItSpeaksAgainOnceTheCooldownHasPassed() {
        let now = Date()
        XCTAssertEqual(
            BreakAdvice.decide(
                timingSeconds: 90 * 60, after: 50,
                lastSuggestedAt: now.addingTimeInterval(-20 * 60), now: now
            ),
            .due(workedMinutes: 90)
        )
    }

    // MARK: - What it says without being asked

    func testAnOrdinaryDayGetsNoUnpromptedComment() {
        XCTAssertFalse(status(openToday: 3, focus: .overdue(count: 3)).wantsAttention)
        XCTAssertFalse(status(timingMinutes: 20).wantsAttention)
        XCTAssertFalse(status().wantsAttention)
    }

    func testABreakIsWorthSpeakingUpFor() {
        XCTAssertTrue(status(breakAdvice: .due(workedMinutes: 60)).wantsAttention)
    }

    func testAMeetingAboutToStartIsWorthSpeakingUpFor() {
        let soon = PetStatus.Event(title: "Standup", start: Date(), minutesAway: 5)
        XCTAssertTrue(status(nextEvent: soon).wantsAttention)
    }

    /// Far enough away and it is not "coming up", it is just something in the
    /// calendar — and saying so all morning is noise.
    func testAMeetingAnHourOffIsNot() {
        let later = PetStatus.Event(title: "Review", start: Date(), minutesAway: 40)
        XCTAssertFalse(status(nextEvent: later).wantsAttention)
    }

    // MARK: - The one line it shows

    func testTheBreakOutranksEverythingElse() {
        let line = status(
            openToday: 5,
            focus: .overdue(count: 5),
            nextEvent: PetStatus.Event(title: "Standup", start: Date(), minutesAway: 3),
            timingMinutes: 61,
            breakAdvice: .due(workedMinutes: 61)
        ).headline
        XCTAssertTrue(line.contains("without a break"), line)
    }

    func testAMeetingOutranksTheTaskList() {
        let line = status(
            openToday: 5,
            focus: .overdue(count: 5),
            nextEvent: PetStatus.Event(title: "Standup", start: Date(), minutesAway: 3)
        ).headline
        XCTAssertTrue(line.contains("Standup"), line)
    }

    func testAMeetingAlreadyStartedSaysNowRatherThanCountingBackwards() {
        let line = status(
            nextEvent: PetStatus.Event(title: "Standup", start: Date(), minutesAway: -2)
        ).headline
        XCTAssertEqual(line, "Standup — now.")
    }

    func testAnEmptyDayIsReportedAsEmptyRatherThanAsFree() {
        XCTAssertEqual(status().headline, "Nothing scheduled.")
    }

    // MARK: - The face

    func testTheMoodShowsTheMostUrgentThing() {
        XCTAssertEqual(status(breakAdvice: .due(workedMinutes: 60)).mood, .restDue)
        XCTAssertEqual(status(timingMinutes: 10).mood, .working)
        XCTAssertEqual(status(openToday: 3, focus: .overdue(count: 3)).mood, .behind)
        XCTAssertEqual(status(focus: .allDone(count: 4)).mood, .clear)
        XCTAssertEqual(status(focus: .next(item("Later", at: 15))).mood, .idle)
    }

    /// A break outranks the timer that caused it: both are true, and only one
    /// is worth a face.
    func testRestingOutranksWorking() {
        XCTAssertEqual(
            status(timingMinutes: 61, breakAdvice: .due(workedMinutes: 61)).mood,
            .restDue
        )
    }
}
