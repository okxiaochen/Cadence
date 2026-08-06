import XCTest
@testable import Cadence

final class CaptureParserTests: XCTestCase {

    /// Fixed reference point so weekday and "tomorrow" maths are deterministic.
    /// 2026-08-05 is a Wednesday.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 10, minute: 0))!
    }

    private func parse(_ input: String) -> ParsedCapture {
        CaptureParser.parse(input, now: now, calendar: calendar)
    }

    // MARK: - Tokens

    func testPlainTitle() {
        let result = parse("Fix the login bug")
        XCTAssertEqual(result.title, "Fix the login bug")
        XCTAssertTrue(result.tagNames.isEmpty)
        XCTAssertNil(result.projectName)
        XCTAssertEqual(result.priority, .none)
    }

    func testAllTokensTogether() {
        let result = parse("Fix login bug #bug #urgent @Cadence !2 ~45m")
        XCTAssertEqual(result.title, "Fix login bug")
        XCTAssertEqual(result.tagNames, ["bug", "urgent"])
        XCTAssertEqual(result.projectName, "Cadence")
        XCTAssertEqual(result.priority, .medium)
        XCTAssertEqual(result.estimateMinutes, 45)
    }

    func testTokensInTheMiddleOfTheLine() {
        let result = parse("Write the #docs section for @Cadence today")
        XCTAssertEqual(result.title, "Write the section for")
        XCTAssertEqual(result.tagNames, ["docs"])
        XCTAssertEqual(result.projectName, "Cadence")
    }

    func testEmailIsNotReadAsAProject() {
        // The @ must start a word, so an address stays part of the title.
        let result = parse("Reply to sam@example.com")
        XCTAssertNil(result.projectName)
        XCTAssertEqual(result.title, "Reply to sam@example.com")
    }

    func testPriorityWords() {
        XCTAssertEqual(parse("Ship it !high").priority, .high)
        XCTAssertEqual(parse("Ship it !1").priority, .low)
        XCTAssertEqual(parse("Ship it !medium").priority, .medium)
    }

    // MARK: - Estimates

    func testEstimateFormats() {
        XCTAssertEqual(CaptureParser.minutes(from: "45m"), 45)
        XCTAssertEqual(CaptureParser.minutes(from: "90"), 90)
        XCTAssertEqual(CaptureParser.minutes(from: "2h"), 120)
        XCTAssertEqual(CaptureParser.minutes(from: "1.5h"), 90)
        XCTAssertEqual(CaptureParser.minutes(from: "1h30m"), 90)
        XCTAssertEqual(CaptureParser.minutes(from: "1h30"), 90)
        XCTAssertNil(CaptureParser.minutes(from: "soon"))
    }

    // MARK: - Dates

    func testTomorrowSetsDueDateNotSchedule() {
        let result = parse("Call the dentist tomorrow")
        XCTAssertEqual(result.title, "Call the dentist")
        XCTAssertNil(result.scheduledAt)
        let expected = calendar.date(from: DateComponents(year: 2026, month: 8, day: 6))!
        XCTAssertEqual(result.dueAt, expected)
    }

    func testDateWithTimeSchedulesInsteadOfDueing() {
        let result = parse("Standup tomorrow 3pm")
        XCTAssertEqual(result.title, "Standup")
        XCTAssertNil(result.dueAt)
        let expected = calendar.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: 15))!
        XCTAssertEqual(result.scheduledAt, expected)
    }

    func testBareTimeAlreadyPassedRollsToTomorrow() {
        // "now" is 10:00; 9am has gone.
        let result = parse("Coffee 9am")
        let expected = calendar.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: 9))!
        XCTAssertEqual(result.scheduledAt, expected)
    }

    func testTwentyFourHourTime() {
        let result = parse("Deploy today 15:30")
        let expected = calendar.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 15, minute: 30))!
        XCTAssertEqual(result.scheduledAt, expected)
    }

    func testWeekdayResolvesForward() {
        // Wednesday 2026-08-05 → "fri" is 2026-08-07.
        let result = parse("Review PRs fri")
        XCTAssertEqual(result.title, "Review PRs")
        XCTAssertEqual(result.dueAt, calendar.date(from: DateComponents(year: 2026, month: 8, day: 7)))
    }

    func testSameWeekdayMeansNextWeek() {
        // "wed" on a Wednesday should not mean today.
        let result = parse("Retro wed")
        XCTAssertEqual(result.dueAt, calendar.date(from: DateComponents(year: 2026, month: 8, day: 12)))
    }

    func testNextWeekdaySkipsAWeek() {
        let result = parse("Plan next fri")
        XCTAssertEqual(result.dueAt, calendar.date(from: DateComponents(year: 2026, month: 8, day: 14)))
    }

    func testInNDays() {
        let result = parse("Follow up in 3 days")
        XCTAssertEqual(result.title, "Follow up")
        XCTAssertEqual(result.dueAt, calendar.date(from: DateComponents(year: 2026, month: 8, day: 8)))
    }

    func testExplicitDate() {
        let result = parse("Taxes 9/15")
        XCTAssertEqual(result.title, "Taxes")
        XCTAssertEqual(result.dueAt, calendar.date(from: DateComponents(year: 2026, month: 9, day: 15)))
    }

    func testPastExplicitDateRollsToNextYear() {
        let result = parse("Renew 1/10")
        XCTAssertEqual(result.dueAt, calendar.date(from: DateComponents(year: 2027, month: 1, day: 10)))
    }

    func testTonightDefaultsToEvening() {
        let result = parse("Read tonight")
        let expected = calendar.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 19))!
        XCTAssertEqual(result.scheduledAt, expected)
    }

    // MARK: - Edge cases

    func testEmptyInputProducesEmptyCapture() {
        XCTAssertTrue(parse("   ").isEmpty)
        XCTAssertTrue(parse("#onlyatag").isEmpty)
    }

    func testWhitespaceIsCollapsed() {
        XCTAssertEqual(parse("Do    the   thing #x").title, "Do the thing")
    }
}
