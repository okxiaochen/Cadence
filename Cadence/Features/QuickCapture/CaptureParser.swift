import Foundation

/// The result of parsing a quick-capture line.
struct ParsedCapture: Equatable {
    var title: String = ""
    var tagNames: [String] = []
    var projectName: String?
    var priority: Priority = .none
    var estimateMinutes: Int?
    /// Set when only a date was given ("tomorrow").
    var dueAt: Date?
    /// Set when a time of day was given ("tomorrow 3pm") — becomes a time block.
    var scheduledAt: Date?

    var isEmpty: Bool { title.isEmpty }

    /// Chips shown under the capture field so it is obvious what was understood.
    var summaryChips: [String] {
        var chips: [String] = []
        if let projectName { chips.append("@\(projectName)") }
        chips.append(contentsOf: tagNames.map { "#\($0)" })
        if priority != .none { chips.append("\(priority.title) priority") }
        if let estimateMinutes { chips.append(Format.duration(estimateMinutes)) }
        if let scheduledAt { chips.append(Format.dateTime(scheduledAt)) }
        else if let dueAt { chips.append("due \(Format.date(dueAt))") }
        return chips
    }
}

/// Parses `Fix login bug #bug @Cadence !2 ~45m tomorrow 3pm` without touching
/// the network or the AI CLI — quick capture has to feel instantaneous, so the
/// grammar is deliberately small, explicit, and fully testable.
enum CaptureParser {

    static func parse(
        _ input: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ParsedCapture {
        var result = ParsedCapture()
        var text = input

        // Sigil tokens, longest-lived first so removal does not disturb others.
        text = extract(pattern: #"(?:^|(?<=\s))#([\p{L}\p{N}_-]+)"#, from: text) { match in
            result.tagNames.append(match)
        }
        text = extract(pattern: #"(?:^|(?<=\s))@([\p{L}\p{N}_-]+)"#, from: text) { match in
            if result.projectName == nil { result.projectName = match }
        }
        text = extract(pattern: #"(?:^|(?<=\s))!([1-3]|low|med|medium|high)\b"#, from: text) { match in
            result.priority = priority(from: match)
        }
        text = extract(pattern: #"(?:^|(?<=\s))~(\S+)"#, from: text) { match in
            if let minutes = minutes(from: match) { result.estimateMinutes = minutes }
        }

        // Date and time phrases.
        let dateResult = DatePhraseParser.parse(text, now: now, calendar: calendar)
        text = dateResult.remainder
        if let time = dateResult.timeOfDay {
            let day = dateResult.date ?? calendar.startOfDay(for: now)
            var components = calendar.dateComponents([.year, .month, .day], from: day)
            components.hour = time.hour
            components.minute = time.minute
            var scheduled = calendar.date(from: components)
            // A bare time that already passed today means tomorrow.
            if dateResult.date == nil, let candidate = scheduled, candidate < now {
                scheduled = calendar.date(byAdding: .day, value: 1, to: candidate)
            }
            result.scheduledAt = scheduled
        } else if let date = dateResult.date {
            result.dueAt = calendar.startOfDay(for: date)
        }

        result.title = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    // MARK: - Token helpers

    /// Removes every match of `pattern` from `text`, reporting capture group 1.
    private static func extract(
        pattern: String,
        from text: String,
        onMatch: (String) -> Void
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let full = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: full)
        guard !matches.isEmpty else { return text }

        var output = text
        for match in matches {
            if let range = Range(match.range(at: 1), in: text) {
                onMatch(String(text[range]))
            }
        }
        // Remove back to front so earlier ranges stay valid.
        for match in matches.reversed() {
            if let range = Range(match.range, in: output) {
                output.replaceSubrange(range, with: "")
            }
        }
        return output
    }

    private static func priority(from token: String) -> Priority {
        switch token.lowercased() {
        case "3", "high": .high
        case "2", "med", "medium": .medium
        case "1", "low": .low
        default: .none
        }
    }

    /// `45m`, `90`, `2h`, `1.5h`, `1h30`, `1h30m` → minutes.
    static func minutes(from token: String) -> Int? {
        let value = token.lowercased()

        if let match = value.firstMatch(#"^(\d+)h(\d+)m?$"#), match.count == 2,
           let hours = Int(match[0]), let mins = Int(match[1]) {
            return hours * 60 + mins
        }
        if let match = value.firstMatch(#"^(\d+(?:\.\d+)?)\s*(?:h|hr|hrs|hour|hours)$"#), match.count == 1,
           let hours = Double(match[0]) {
            return Int((hours * 60).rounded())
        }
        if let match = value.firstMatch(#"^(\d+)\s*(?:m|min|mins|minute|minutes)?$"#), match.count == 1,
           let mins = Int(match[0]) {
            return mins
        }
        return nil
    }
}

// MARK: - Dates

struct TimeOfDay: Equatable {
    var hour: Int
    var minute: Int
}

/// Recognises the handful of date phrases worth supporting. Deliberately does
/// not use `NSDataDetector`: it happily reads "2" as a date, which makes
/// capture unpredictable in exactly the cases that matter.
enum DatePhraseParser {

    struct Result: Equatable {
        var date: Date?
        var timeOfDay: TimeOfDay?
        var remainder: String
    }

    private static let weekdays: [String: Int] = [
        "sunday": 1, "sun": 1, "monday": 2, "mon": 2, "tuesday": 3, "tue": 3, "tues": 3,
        "wednesday": 4, "wed": 4, "thursday": 5, "thu": 5, "thur": 5, "thurs": 5,
        "friday": 6, "fri": 6, "saturday": 7, "sat": 7
    ]

    static func parse(_ text: String, now: Date, calendar: Calendar) -> Result {
        var remainder = text
        var date: Date?
        var time: TimeOfDay?

        // Time of day: "3pm", "at 3:30pm", "15:00"
        remainder = consume(#"(?:^|(?<=\s))(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#, in: remainder) { groups in
            guard let rawHour = Int(groups[0]) else { return }
            let minute = Int(groups[1]) ?? 0
            let isPM = groups.last?.lowercased() == "pm"
            var hour = rawHour % 12
            if isPM { hour += 12 }
            time = TimeOfDay(hour: hour, minute: minute)
        }
        if time == nil {
            remainder = consume(#"(?:^|(?<=\s))(?:at\s+)?([01]?\d|2[0-3]):([0-5]\d)\b"#, in: remainder) { groups in
                guard let hour = Int(groups[0]), let minute = Int(groups[1]) else { return }
                time = TimeOfDay(hour: hour, minute: minute)
            }
        }

        let startOfToday = calendar.startOfDay(for: now)

        // Relative day words
        remainder = consume(#"(?:^|(?<=\s))(today|tonight|tomorrow|tmr|tmw|eod)\b"#, in: remainder) { groups in
            switch groups[0].lowercased() {
            case "tomorrow", "tmr", "tmw":
                date = calendar.date(byAdding: .day, value: 1, to: startOfToday)
            case "tonight":
                date = startOfToday
                if time == nil { time = TimeOfDay(hour: 19, minute: 0) }
            default:
                date = startOfToday
            }
        }

        // "in 3 days" / "in 2 weeks"
        if date == nil {
            remainder = consume(#"(?:^|(?<=\s))in\s+(\d+)\s*(day|days|week|weeks)\b"#, in: remainder) { groups in
                guard let amount = Int(groups[0]) else { return }
                let unit = groups[1].lowercased()
                let days = unit.hasPrefix("week") ? amount * 7 : amount
                date = calendar.date(byAdding: .day, value: days, to: startOfToday)
            }
        }

        // "next monday" / "mon"
        if date == nil {
            let names = weekdays.keys.sorted { $0.count > $1.count }.joined(separator: "|")
            remainder = consume(#"(?:^|(?<=\s))(next\s+)?(\#(names))\b"#, in: remainder) { groups in
                let wantsNextWeek = !groups[0].isEmpty
                guard let weekday = weekdays[groups[1].lowercased()] else { return }
                date = nextDate(weekday: weekday, after: startOfToday, skipAWeek: wantsNextWeek, calendar: calendar)
            }
        }

        // "8/12" or "8/12/2026"
        if date == nil {
            remainder = consume(#"(?:^|(?<=\s))(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b"#, in: remainder) { groups in
                guard let month = Int(groups[0]), let day = Int(groups[1]),
                      (1...12).contains(month), (1...31).contains(day) else { return }
                var components = calendar.dateComponents([.year], from: startOfToday)
                if let year = Int(groups[2]) {
                    components.year = year < 100 ? 2000 + year : year
                }
                components.month = month
                components.day = day
                guard var candidate = calendar.date(from: components) else { return }
                // A bare M/D in the past means next year.
                if groups[2].isEmpty, candidate < startOfToday,
                   let bumped = calendar.date(byAdding: .year, value: 1, to: candidate) {
                    candidate = bumped
                }
                date = candidate
            }
        }

        return Result(
            date: date,
            timeOfDay: time,
            remainder: remainder.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        )
    }

    private static func nextDate(
        weekday: Int,
        after start: Date,
        skipAWeek: Bool,
        calendar: Calendar
    ) -> Date? {
        let current = calendar.component(.weekday, from: start)
        var delta = (weekday - current + 7) % 7
        if delta == 0 { delta = 7 }          // "mon" on a Monday means next Monday
        if skipAWeek && delta < 7 { delta += 7 }
        return calendar.date(byAdding: .day, value: delta, to: start)
    }

    /// Consumes the first match of `pattern`, handing capture groups to `body`.
    private static func consume(
        _ pattern: String,
        in text: String,
        body: ([String]) -> Void
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return text }

        var groups: [String] = []
        for index in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: index), in: text) {
                groups.append(String(text[range]))
            } else {
                groups.append("")
            }
        }
        body(groups)

        var output = text
        if let range = Range(match.range, in: output) {
            output.replaceSubrange(range, with: "")
        }
        return output
    }
}

// MARK: - Small helpers

extension String {
    /// Capture groups of the first match, or nil.
    func firstMatch(_ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self))
        else { return nil }
        var groups: [String] = []
        for index in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: index), in: self) {
                groups.append(String(self[range]))
            }
        }
        return groups
    }
}

enum Format {
    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    /// How long ago something happened, in whole days: "today", "yesterday",
    /// "5d ago". Days rather than hours because that is the unit a task that
    /// has been sitting around is measured in.
    static func daysAgo(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        switch days {
        case ..<0: return Self.date(date)
        case 0: return "today"
        case 1: return "yesterday"
        default: return "\(days)d ago"
        }
    }

    /// "Today", "Tomorrow", "Overdue by 2d", or a short date.
    static func relativeDue(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfDue = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startOfToday, to: startOfDue).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case ..<(-1): return "\(-days)d overdue"
        case 2...6: return date.formatted(.dateTime.weekday(.wide))
        default: return Self.date(date)
        }
    }
}
