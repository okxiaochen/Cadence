import XCTest
@testable import Cadence

/// The payloads here are trimmed copies of what `meegle mywork todo` actually
/// returned, not what the documentation describes. Every quirk asserted below
/// was found by calling the CLI; none of it is written down anywhere.
final class MeegleTests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    private var onePage: Data {
        data("""
        {"list": [
          {"node_info": {"node_name": "", "node_state_key": ""},
           "project_key": "6a80e2a4d25cc38cce48e457",
           "project_name": "App Development",
           "schedule": {"end_time": "", "start_time": ""},
           "state_info": {"end_state_key_name": "", "start_state_key_name": "RESOLVED"},
           "work_item_info": {"work_item_id": 14160326,
                              "work_item_name": "User cannot log-in\\n",
                              "work_item_type_key": "issue"}}
        ]}
        """)
    }

    // MARK: - The four things a naive decoder gets wrong

    func testTrailingNewlineIsStrippedFromTheTitle() throws {
        // Untrimmed it walks straight into a task title.
        let items = try MeegleParser.workItems(from: onePage)
        XCTAssertEqual(items.first?.title, "User cannot log-in")
    }

    func testEmptyStringsReadAsAbsentRatherThanFailing() throws {
        // This API says "not set" with "", not null and not a missing key.
        let items = try MeegleParser.workItems(from: onePage)
        let item = try XCTUnwrap(items.first)
        XCTAssertNil(item.startAt)
        XCTAssertNil(item.endAt)
        XCTAssertNil(item.nodeName)
        XCTAssertEqual(item.stateName, "RESOLVED")
    }

    func testTheStableKeyPairsSpaceWithItemID() throws {
        // work_item_id is a JSON number and repeats between spaces, so neither
        // field alone can be the key a re-sync matches on.
        let items = try MeegleParser.workItems(from: onePage)
        XCTAssertEqual(items.first?.id, "meegle:6a80e2a4d25cc38cce48e457:14160326")
    }

    func testTheSameItemIDInTwoSpacesStaysTwoItems() throws {
        let items = try MeegleParser.workItems(from: data("""
        {"list": [
          {"project_key": "space-a", "project_name": "A",
           "work_item_info": {"work_item_id": 1, "work_item_name": "One", "work_item_type_key": "issue"}},
          {"project_key": "space-b", "project_name": "B",
           "work_item_info": {"work_item_id": 1, "work_item_name": "One", "work_item_type_key": "issue"}}
        ]}
        """))
        XCTAssertEqual(Set(items.map(\.id)).count, 2)
    }

    // MARK: - Shape of the response

    func testAPagePastTheEndIsEmptyRatherThanFlagged() throws {
        // There is no has_more and no next_page_token; an empty list is the
        // only end-of-pages signal there is.
        XCTAssertTrue(try MeegleParser.workItems(from: data(#"{"list": []}"#)).isEmpty)
        XCTAssertTrue(try MeegleParser.workItems(from: data(#"{"list": null}"#)).isEmpty)
        XCTAssertTrue(try MeegleParser.workItems(from: data("{}")).isEmpty)
    }

    func testTheEnvelopeFormIsAcceptedToo() throws {
        let items = try MeegleParser.workItems(from: data("""
        {"data": {"list": [{"project_key": "s", "project_name": "S",
          "work_item_info": {"work_item_id": 7, "work_item_name": "Seven",
                             "work_item_type_key": "issue"}}]},
         "error": null, "meta": {"tool": "list_todo"}}
        """))
        XCTAssertEqual(items.map(\.title), ["Seven"])
    }

    func testOneMalformedRowDoesNotLoseThePage() throws {
        let items = try MeegleParser.workItems(from: data("""
        {"list": [
          {"project_key": "s", "work_item_info": {"work_item_name": "No id"}},
          {"project_key": "s", "project_name": "S",
           "work_item_info": {"work_item_id": 2, "work_item_name": "Fine",
                              "work_item_type_key": "issue"}}
        ]}
        """))
        XCTAssertEqual(items.map(\.title), ["Fine"])
    }

    func testGarbageIsAnErrorNotAnEmptyList() {
        XCTAssertThrowsError(try MeegleParser.workItems(from: data("not json")))
    }

    // MARK: - Dates
    //
    // The wire format is unverified: no work item in the tenant this was built
    // against had a schedule set. Both plausible forms are handled, and an
    // unreadable one degrades to "no date" rather than losing the item.

    func testISO8601SchedulesAreRead() throws {
        let parsed = try XCTUnwrap(MeegleParser.date(from: "2026-08-15T22:06:12Z"))
        XCTAssertEqual(ISO8601DateFormatter().string(from: parsed), "2026-08-15T22:06:12Z")
    }

    func testFractionalSecondsAreReadToo() throws {
        // Sibling timestamps come back both ways.
        XCTAssertNotNil(MeegleParser.date(from: "2026-08-15T22:06:12.500Z"))
    }

    func testEpochSecondsAndMillisecondsAreBothRead() {
        let seconds = MeegleParser.date(from: 1_786_939_572)
        let milliseconds = MeegleParser.date(from: 1_786_939_572_000)
        XCTAssertEqual(seconds, milliseconds)
        XCTAssertEqual(seconds, Date(timeIntervalSince1970: 1_786_939_572))
    }

    /// How dates arrive inside `work_item_fields` — an object, so every scalar
    /// branch would miss it.
    func testTheObjectFormUsedByWorkItemFieldsIsRead() throws {
        let parsed = try XCTUnwrap(MeegleParser.date(from: [
            "iso_time": "2026-08-15T22:06:11Z",
            "timestamp": 1_786_831_571
        ]))
        XCTAssertEqual(ISO8601DateFormatter().string(from: parsed), "2026-08-15T22:06:11Z")
    }

    func testTheObjectFormFallsBackToItsTimestamp() {
        XCTAssertEqual(
            MeegleParser.date(from: ["iso_time": "", "timestamp": 1_786_939_572]),
            Date(timeIntervalSince1970: 1_786_939_572)
        )
    }

    /// The form `workhour list-schedule` insists on for its own arguments.
    func testABareDayIsReadInTheLocalZone() throws {
        let parsed = try XCTUnwrap(MeegleParser.date(from: "2026-08-15"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: parsed),
            DateComponents(year: 2026, month: 8, day: 15),
            "a bare day means the user's day, not a UTC instant"
        )
    }

    func testAnUnreadableDateBecomesNoDateRatherThanAnError() {
        XCTAssertNil(MeegleParser.date(from: "next Tuesday"))
        XCTAssertNil(MeegleParser.date(from: ""))
        XCTAssertNil(MeegleParser.date(from: 0))
        XCTAssertNil(MeegleParser.date(from: nil))
    }

    // MARK: - Paging

    func testPagesAreFollowedUntilOneComesBackShort() throws {
        let pages = Counter()
        let client = MeegleClient { arguments in
            let page = pageNumber(arguments)
            pages.record(page)
            // A full page is 50, so page 1 being full is what asks for page 2.
            let count = page == "1" ? 50 : 3
            let rows = (0..<count).map {
                """
                {"project_key": "s", "project_name": "S",
                 "work_item_info": {"work_item_id": \(page == "1" ? $0 : 100 + $0),
                                    "work_item_name": "Item", "work_item_type_key": "t"}}
                """
            }
            return Data("{\"list\": [\(rows.joined(separator: ","))]}".utf8)
        }
        let items = try client.workItems(action: .todo)
        XCTAssertEqual(items.count, 53)
        XCTAssertEqual(pages.values, ["1", "2"], "a short page ends the walk")
    }

    func testAFullPageFollowedByAnEmptyOneAlsoStops() throws {
        let client = MeegleClient { arguments in
            guard pageNumber(arguments) == "1" else { return Data(#"{"list": []}"#.utf8) }
            let rows = (0..<50).map {
                """
                {"project_key": "s", "project_name": "S",
                 "work_item_info": {"work_item_id": \($0), "work_item_name": "I",
                                    "work_item_type_key": "t"}}
                """
            }
            return Data("{\"list\": [\(rows.joined(separator: ","))]}".utf8)
        }
        XCTAssertEqual(try client.workItems(action: .todo).count, 50)
    }

    func testAnItemRepeatedAcrossPagesIsCountedOnce() throws {
        // A page boundary that shifts between requests would otherwise turn one
        // work item into two tasks.
        let client = MeegleClient { arguments in
            let page = pageNumber(arguments)
            guard page == "1" || page == "2" else {
                return Data(#"{"list": []}"#.utf8)
            }
            let rows = (0..<50).map { index in
                """
                {"project_key": "s", "project_name": "S",
                 "work_item_info": {"work_item_id": \(page == "1" ? index : index + 49),
                                    "work_item_name": "I", "work_item_type_key": "t"}}
                """
            }
            return Data("{\"list\": [\(rows.joined(separator: ","))]}".utf8)
        }
        let items = try client.workItems(action: .todo)
        XCTAssertEqual(items.count, Set(items.map(\.id)).count)
        XCTAssertEqual(items.count, 99, "one id overlaps the two pages")
    }

    func testTheActionIsPassedThrough() throws {
        let seen = Counter()
        let client = MeegleClient { arguments in
            if let index = arguments.firstIndex(of: "--action") {
                seen.record(arguments[index + 1])
            }
            return Data(#"{"list": []}"#.utf8)
        }
        for action in MeegleAction.allCases { _ = try client.workItems(action: action) }
        XCTAssertEqual(seen.values, ["todo", "done", "overdue", "this_week"])
    }
}

/// `--page-num` is not the last argument — `--format json` follows it — so the
/// stubs have to read the flag rather than the tail. Free rather than a method:
/// the stubs are `@Sendable` and must not capture the test case.
private func pageNumber(_ arguments: [String]) -> String {
    guard let index = arguments.firstIndex(of: "--page-num"),
          arguments.indices.contains(index + 1) else { return "?" }
    return arguments[index + 1]
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func record(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
}
