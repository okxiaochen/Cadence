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
        justEnded: PetStatus.Event? = nil,
        timingMinutes: Int? = nil,
        breakAdvice: BreakAdvice = .none
    ) -> PetStatus {
        PetStatus(
            openToday: openToday, focus: focus, nextEvent: nextEvent,
            justEnded: justEnded, timingMinutes: timingMinutes,
            breakAdvice: breakAdvice
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

    // MARK: - The day as one list
    //
    // The first version answered "how many" when the question was "what". These
    // pin down the list it answers with now.

    @MainActor
    private func model() throws -> AppModel {
        AppModel(database: try AppDatabase.inMemory())
    }

    private func day(_ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 17, hour: hour, minute: minute
        ))!
    }

    @MainActor
    func testTasksAndEventsShareOneListInTimeOrder() throws {
        let model = try model()
        model.agendaItems = [
            block("Deep work", from: day(14)),
            block("Standup prep", from: day(9, 30))
        ]
        let lines = model.todayLines(now: day(8))
        // Events cannot be injected without EventKit, so this covers the task
        // half and the ordering rule they share.
        XCTAssertEqual(lines.map(\.title), ["Standup prep", "Deep work"])
        XCTAssertTrue(lines.allSatisfy { $0.kind == .task })
    }

    @MainActor
    func testUntimedWorkLeadsTheDayRatherThanLandingAtMidnight() throws {
        let model = try model()
        model.agendaItems = [
            block("At two", from: day(14)),
            allDay("Due today", on: day(0))
        ]
        XCTAssertEqual(model.todayLines(now: day(8)).map(\.title), ["Due today", "At two"])
    }

    @MainActor
    func testWorkLeftOverFromEarlierDaysIsStillTodaysProblem() throws {
        let model = try model()
        model.agendaItems = [block("From Monday", from: day(9).addingTimeInterval(-3 * 86_400))]
        let lines = model.todayLines(now: day(10))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.daysLate, 3)
    }

    @MainActor
    func testFinishedWorkIsNotOnTheList() throws {
        let model = try model()
        var done = block("Done", from: day(9))
        done.todo.status = .done
        model.agendaItems = [done, block("Not done", from: day(11))]
        XCTAssertEqual(model.todayLines(now: day(8)).map(\.title), ["Not done"])
    }

    @MainActor
    func testTheListIsCappedSoThePanelStaysAPanel() throws {
        let model = try model()
        model.agendaItems = (0..<40).map { block("Task \($0)", from: day(9).addingTimeInterval(Double($0) * 60)) }
        XCTAssertEqual(model.todayLines(now: day(8), limit: 12).count, 12)
    }

    private func block(_ title: String, from start: Date) -> AgendaItem {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return AgendaItem(
            todo: Todo(title: title),
            interval: DateInterval(start: start, duration: 3600),
            day: calendar.startOfDay(for: start)
        )
    }

    private func allDay(_ title: String, on start: Date) -> AgendaItem {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return AgendaItem(
            todo: Todo(title: title),
            interval: nil,
            day: calendar.startOfDay(for: start)
        )
    }

    // MARK: - After a meeting
    //
    // The moment worth catching: what a meeting produced is clearest in the
    // thirty seconds after it and gone by the time anyone opens a task list.

    func testAMeetingThatJustEndedIsWorthAskingAbout() {
        let ended = PetStatus.Event(title: "Standup", start: Date(), minutesAway: -35)
        XCTAssertTrue(status(justEnded: ended).wantsAttention)
        XCTAssertEqual(
            status(justEnded: ended).headline,
            "Standup — anything to follow up?"
        )
    }

    /// Being late to the next thing matters more than tidying up the last one.
    func testSomethingStartingShortlyOutranksTheOneThatEnded() {
        let line = status(
            nextEvent: PetStatus.Event(title: "Review", start: Date(), minutesAway: 4),
            justEnded: PetStatus.Event(title: "Standup", start: Date(), minutesAway: -35)
        ).headline
        XCTAssertTrue(line.contains("Review"), line)
    }

    func testABreakStillOutranksBoth() {
        let line = status(
            nextEvent: PetStatus.Event(title: "Review", start: Date(), minutesAway: 4),
            justEnded: PetStatus.Event(title: "Standup", start: Date(), minutesAway: -35),
            breakAdvice: .due(workedMinutes: 70)
        ).headline
        XCTAssertTrue(line.contains("without a break"), line)
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

/// Which of the two things a typed line means.
///
/// It is a heuristic and allowed to be wrong: guessing "task" for a question
/// makes a task, which is visible and one click to undo. Guessing "question"
/// for a task costs thirty seconds and a model call, which is the worse of the
/// two, so the doubt leans towards capture.
@MainActor
final class PetInputTests: XCTestCase {

    func testAPlainNounPhraseIsATask() {
        for text in ["Buy milk", "Fix the flaky scheduler test", "Renew TLS cert #ops ~30m"] {
            XCTAssertTrue(PetView.looksLikeATask(text), text)
        }
    }

    func testAQuestionIsNot() {
        for text in ["what should I do next?", "有什么没做完的？"] {
            XCTAssertFalse(PetView.looksLikeATask(text), text)
        }
    }

    func testAnInstructionIsNot() {
        for text in [
            "plan my afternoon",
            "move the roadmap to Friday",
            "帮我看看今天还有什么",
            "整理一下未读消息"
        ] {
            XCTAssertFalse(PetView.looksLikeATask(text), text)
        }
    }

    /// Capture is a line; a request is a sentence.
    func testSomethingLongIsAskedRatherThanCaptured() {
        let sentence = "go through everything assigned to me and tell me which "
            + "of it actually matters before the end of this week"
        XCTAssertFalse(PetView.looksLikeATask(sentence))
    }

    // MARK: - Saved buttons

    func testAFreshInstallHasSomethingInTheRow() {
        // An empty row teaches nobody what the row is for.
        XCTAssertFalse([PetPrompt].decoded(from: nil).isEmpty)
    }

    func testAnEmptyButtonIsNotShown() {
        XCTAssertFalse(PetPrompt(title: "", prompt: "do a thing").isUsable)
        XCTAssertFalse(PetPrompt(title: "Go", prompt: "   ").isUsable)
        XCTAssertTrue(PetPrompt(title: "Go", prompt: "do a thing").isUsable)
    }

    func testButtonsSurviveARoundTrip() throws {
        let saved = [PetPrompt(title: "Catch up", prompt: "what did I miss?")]
        XCTAssertEqual([PetPrompt].decoded(from: saved.encoded), saved)
    }
}
