import Foundation

/// One Meegle work item, as `meegle mywork todo` actually returns it.
///
/// Modelled on real responses rather than on the documentation, which describes
/// the command surface but not the payload. Four things the docs do not mention,
/// and every one of them breaks a naive `Codable` conformance:
///
/// - **Absent values are the empty string**, not `null` and not a missing key.
///   `schedule.start_time == ""` has to read as "no date" rather than fail.
/// - **`work_item_name` carries a trailing newline.** Untrimmed it walks
///   straight into a task title.
/// - **`work_item_id` is a JSON number** while `project_key` is a string, so the
///   stable key has to be built rather than lifted from one field.
/// - **`work_item_type_key` is sometimes a readable slug (`"issue"`) and
///   sometimes an opaque id.** It is an identifier, never a label to show.
struct MeegleWorkItem: Equatable, Hashable, Identifiable {
    var workItemID: Int
    var title: String
    var typeKey: String
    var projectKey: String
    var projectName: String
    /// The workflow node it is sitting on, in spaces that use nodes.
    var nodeName: String?
    /// `state_info.start_state_key_name` — the state it entered, when set.
    var stateName: String?
    var startAt: Date?
    var endAt: Date?

    /// Stable across syncs and unique across spaces.
    ///
    /// The pair is what Meegle itself addresses an item by; `work_item_id`
    /// alone repeats between spaces. This is the key a re-sync upserts on, so
    /// running the import twice revises tasks instead of duplicating them —
    /// the same trick `MemoryRepository.upsert` relies on.
    var id: String { "meegle:\(projectKey):\(workItemID)" }
}

/// Which of `mywork todo`'s four lists to ask for.
enum MeegleAction: String, CaseIterable, Sendable {
    case todo, done, overdue, thisWeek = "this_week"

    var title: String {
        switch self {
        case .todo: "To do"
        case .done: "Done"
        case .overdue: "Overdue"
        case .thisWeek: "This week"
        }
    }
}

/// Turns the CLI's JSON into work items. Pure, so every quirk above is covered
/// by a test that needs neither a network nor a login.
enum MeegleParser {

    /// The payload is `{"list": [...]}`, or the same under `data` when the
    /// caller passed `--envelope`. Both are accepted so the tool does not break
    /// if the flag is ever added.
    static func workItems(from data: Data) throws -> [MeegleWorkItem] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MeegleError.badResponse("top level was not an object")
        }
        let container = (root["data"] as? [String: Any]) ?? root
        // A page past the end is `{"list": null}` rather than an empty array,
        // and that is the only signal there is — the response carries no
        // `has_more` and no `next_page_token`.
        guard let list = container["list"] as? [[String: Any]] else { return [] }
        return list.compactMap(workItem(from:))
    }

    /// Returns nil for a row missing the identity fields; one malformed row
    /// should not lose the rest of the page.
    static func workItem(from raw: [String: Any]) -> MeegleWorkItem? {
        guard let info = raw["work_item_info"] as? [String: Any],
              let workItemID = integer(info["work_item_id"]),
              let title = nonEmpty(info["work_item_name"]),
              let projectKey = nonEmpty(raw["project_key"])
        else { return nil }

        let schedule = raw["schedule"] as? [String: Any] ?? [:]
        let node = raw["node_info"] as? [String: Any] ?? [:]
        let state = raw["state_info"] as? [String: Any] ?? [:]

        return MeegleWorkItem(
            workItemID: workItemID,
            title: title,
            typeKey: nonEmpty(info["work_item_type_key"]) ?? "",
            projectKey: projectKey,
            projectName: nonEmpty(raw["project_name"]) ?? "",
            nodeName: nonEmpty(node["node_name"]),
            stateName: nonEmpty(state["start_state_key_name"]),
            startAt: date(from: schedule["start_time"]),
            endAt: date(from: schedule["end_time"])
        )
    }

    /// Empty and whitespace-only strings are how this API says "not set".
    static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// Accepts every date shape this API has been observed to use.
    ///
    /// There are at least four, in one product:
    ///
    /// - `{"iso_time": "2026-08-15T22:06:11Z", "timestamp": 1786831571}` — how
    ///   dates arrive inside `work_item_fields`;
    /// - a bare ISO 8601 string, with or without fractional seconds, as
    ///   `create_time` and `update_time` use;
    /// - `2006-01-01`, which `workhour list-schedule` demands of its arguments;
    /// - epoch seconds or milliseconds.
    ///
    /// **`schedule.start_time` populated is still unverified**: no work item in
    /// the tenant this was built against had a schedule, and the issue type
    /// there has no schedule field to set — its 17 fields simply do not include
    /// one. Taking every shape is the closest thing to a guess-free answer, and
    /// anything unrecognised returns nil rather than throwing: a date we cannot
    /// read costs one date, while a decode error would cost the whole page.
    static func date(from value: Any?) -> Date? {
        // The object form first — it is a dictionary, so none of the scalar
        // branches below would ever see it.
        if let object = value as? [String: Any] {
            return date(from: object["iso_time"]) ?? date(from: object["timestamp"])
        }
        if let text = nonEmpty(value) {
            if let parsed = iso8601(text) { return parsed }
            if let parsed = plainDay(text) { return parsed }
            if let seconds = Double(text) { return epoch(seconds) }
            return nil
        }
        if let number = value as? Double { return number == 0 ? nil : epoch(number) }
        if let number = value as? Int { return number == 0 ? nil : epoch(Double(number)) }
        return nil
    }

    private static func iso8601(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    /// `yyyy-MM-dd` with no time. Read in the user's own zone, because a bare
    /// day means their day — reading it as UTC lands the evening before for
    /// anyone west of Greenwich.
    private static func plainDay(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }

    /// Milliseconds are told apart by magnitude: anything past year 5138 in
    /// seconds is milliseconds in every practical case.
    private static func epoch(_ value: Double) -> Date {
        value > 100_000_000_000
            ? Date(timeIntervalSince1970: value / 1000)
            : Date(timeIntervalSince1970: value)
    }
}

enum MeegleError: LocalizedError, Equatable {
    case notInstalled
    case notAuthenticated
    case badResponse(String)
    case failed(String)
    case timedOut(seconds: Int)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "The meegle CLI was not found. Install it with "
                + "`npx @lark-project/meegle@latest install`."
        case .notAuthenticated:
            "Not logged in to Meegle. Run `meegle auth login` in a terminal."
        case .badResponse(let why):
            "Could not read the Meegle response: \(why)"
        case .failed(let message):
            "meegle failed: \(message)"
        case .timedOut(let seconds):
            "meegle did not answer within \(seconds)s."
        }
    }
}
