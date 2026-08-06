import Foundation

/// A concrete slot the model can choose. Never a range for it to do maths on —
/// the whole point is that the model picks from candidates rather than
/// computing availability itself (AI-INTEGRATION.md §1, §4).
struct SlotCandidate: Equatable, Codable {
    var start: Date
    var end: Date
    /// Lower is better. Composed of the reasons below.
    var score: Double
    var reasons: [String]

    var interval: DateInterval { DateInterval(start: start, end: end) }
}

struct SlotConstraints {
    var durationMinutes: Int
    var range: DateInterval
    var withinWorkingHours: Bool = true
    /// Minutes of breathing room to leave around existing commitments.
    var bufferMinutes: Int = 0
    var notBefore: Date?
    var notAfter: Date?
    var granularityMinutes: Int = 15
    var limit: Int = 8
}

enum SlotFinder {

    /// Ranked slots that fit `constraints`, given the busy intervals and each
    /// day's working hours. Pure and deterministic: same inputs, same output.
    static func find(
        constraints: SlotConstraints,
        busy: [DateInterval],
        workingHours: (Date) -> DateInterval?,
        calendar: Calendar = .current
    ) -> [SlotCandidate] {
        let duration = TimeInterval(max(5, constraints.durationMinutes) * 60)
        let buffer = TimeInterval(max(0, constraints.bufferMinutes) * 60)

        let padded = FreeBusy.merge(busy.map {
            DateInterval(
                start: $0.start.addingTimeInterval(-buffer),
                end: $0.end.addingTimeInterval(buffer)
            )
        })

        var candidates: [SlotCandidate] = []

        for day in days(in: constraints.range, calendar: calendar) {
            let windows = dayWindows(
                day: day,
                constraints: constraints,
                workingHours: workingHours,
                calendar: calendar
            )

            for window in windows {
                for free in FreeBusy.gaps(in: window, busy: padded)
                where free.duration >= duration {
                    candidates.append(contentsOf: slots(
                        in: free,
                        duration: duration,
                        constraints: constraints,
                        calendar: calendar
                    ))
                }
            }
        }

        return Array(
            candidates
                .sorted { lhs, rhs in
                    lhs.score != rhs.score ? lhs.score < rhs.score : lhs.start < rhs.start
                }
                .prefix(max(1, constraints.limit))
        )
    }

    // MARK: - Pieces

    private static func days(in range: DateInterval, calendar: Calendar) -> [Date] {
        var result: [Date] = []
        var cursor = calendar.startOfDay(for: range.start)
        while cursor < range.end {
            result.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    /// The searchable part of a day: working hours if asked for, otherwise the
    /// whole day — then clipped to the request's range and not-before/after.
    private static func dayWindows(
        day: Date,
        constraints: SlotConstraints,
        workingHours: (Date) -> DateInterval?,
        calendar: Calendar
    ) -> [DateInterval] {
        let whole = DateInterval(
            start: calendar.startOfDay(for: day),
            duration: 86_400
        )
        let base: DateInterval?
        if constraints.withinWorkingHours {
            base = workingHours(day)
        } else {
            base = whole
        }
        guard var window = base?.intersection(with: constraints.range) else { return [] }

        if let notBefore = constraints.notBefore, notBefore > window.start {
            guard notBefore < window.end else { return [] }
            window = DateInterval(start: notBefore, end: window.end)
        }
        if let notAfter = constraints.notAfter, notAfter < window.end {
            guard notAfter > window.start else { return [] }
            window = DateInterval(start: window.start, end: notAfter)
        }
        return window.duration > 0 ? [window] : []
    }

    /// Candidate starts inside one free window, on the snap grid.
    private static func slots(
        in free: DateInterval,
        duration: TimeInterval,
        constraints: SlotConstraints,
        calendar: Calendar
    ) -> [SlotCandidate] {
        let step = TimeInterval(max(5, constraints.granularityMinutes) * 60)
        var result: [SlotCandidate] = []
        var start = CalendarLayout.snap(free.start, to: constraints.granularityMinutes, calendar: calendar)
        if start < free.start { start = start.addingTimeInterval(step) }

        // At most a handful per window; the model does not need every offset.
        while start.addingTimeInterval(duration) <= free.end && result.count < 3 {
            var reasons: [String] = []
            // Hours from the start of the whole search, so candidates order
            // earliest-first *across* days, not within each day separately.
            var score = start.timeIntervalSince(constraints.range.start) / 3600

            if abs(free.duration - duration) < 60 {
                score -= 0.5
                reasons.append("fills the gap exactly")
            }
            if start == free.start {
                reasons.append("starts as soon as you are free")
            }

            result.append(SlotCandidate(
                start: start,
                end: start.addingTimeInterval(duration),
                score: score,
                reasons: reasons
            ))
            start = start.addingTimeInterval(max(step, duration / 2))
        }
        return result
    }
}
