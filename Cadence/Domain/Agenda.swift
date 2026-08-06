import Foundation

/// One line in the menu bar agenda: either a scheduled block, or a task that
/// has a day but no time.
struct AgendaItem: Identifiable, Hashable {
    var todo: Todo
    var project: Project?
    /// Nil for an all-day item.
    var interval: DateInterval?
    var blockID: String?
    /// The day this belongs under.
    var day: Date

    var id: String { blockID ?? todo.id }
    var isAllDay: Bool { interval == nil }

    func hasPassed(_ now: Date) -> Bool {
        guard let interval else { return false }
        return interval.end <= now
    }

    func isUnderway(_ now: Date) -> Bool {
        guard let interval else { return false }
        return interval.contains(now)
    }
}

struct AgendaSection: Identifiable, Hashable {
    enum Kind: String {
        case today, tomorrow, upcoming
    }

    var kind: Kind
    var title: String
    var items: [AgendaItem]

    var id: String { kind.rawValue }
}

/// Turns scheduled work into the three groups the menu bar shows. Pure, so the
/// grouping can be tested without a status item or a database.
enum AgendaBuilder {

    /// How far `upcoming` looks ahead.
    static let upcomingDays = 14

    static func sections(
        blocks: [ScheduledBlock],
        allDay: [TodoDetail],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [AgendaSection] {
        sections(
            from: items(blocks: blocks, allDay: allDay, calendar: calendar),
            now: now,
            calendar: calendar
        )
    }

    static func sections(
        from items: [AgendaItem],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [AgendaSection] {
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
              let startOfDayAfter = calendar.date(byAdding: .day, value: 2, to: startOfToday),
              let horizon = calendar.date(byAdding: .day, value: upcomingDays, to: startOfToday)
        else { return [] }

        // Anything still open from before today is shown with today's work —
        // hiding it in a section nobody expands is how things get missed.
        let today = items.filter { $0.day < startOfTomorrow }
        let tomorrow = items.filter { $0.day >= startOfTomorrow && $0.day < startOfDayAfter }
        let upcoming = items.filter { $0.day >= startOfDayAfter && $0.day < horizon }

        return [
            AgendaSection(kind: .today, title: "Today", items: today),
            AgendaSection(kind: .tomorrow, title: "Tomorrow", items: tomorrow),
            AgendaSection(kind: .upcoming, title: "Upcoming", items: upcoming)
        ]
        .filter { !$0.items.isEmpty }
    }

    static func items(
        blocks: [ScheduledBlock],
        allDay: [TodoDetail],
        calendar: Calendar = .current
    ) -> [AgendaItem] {
        let timed = blocks
            .filter { !$0.todo.status.isTerminal }
            .map { block in
                AgendaItem(
                    todo: block.todo,
                    project: block.project,
                    interval: block.interval,
                    blockID: block.block.id,
                    day: calendar.startOfDay(for: block.block.startAt)
                )
            }

        let untimed = allDay
            .filter { !$0.todo.status.isTerminal }
            .compactMap { detail -> AgendaItem? in
                guard let due = detail.todo.dueAt else { return nil }
                return AgendaItem(
                    todo: detail.todo,
                    project: detail.project,
                    interval: nil,
                    blockID: nil,
                    day: calendar.startOfDay(for: due)
                )
            }

        // All-day items lead the day, then everything in time order.
        return (timed + untimed).sorted { lhs, rhs in
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            switch (lhs.interval, rhs.interval) {
            case (nil, nil): return lhs.todo.title < rhs.todo.title
            case (nil, _): return true
            case (_, nil): return false
            case let (left?, right?): return left.start < right.start
            }
        }
    }

    /// What the status item itself says: whatever is happening now, or the next
    /// thing due to start today.
    static func focus(
        in items: [AgendaItem],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> AgendaItem? {
        if let underway = items.first(where: { $0.isUnderway(now) }) { return underway }
        return items.first { item in
            guard let interval = item.interval else { return false }
            // Against `now`, not `isDateInToday`: that reads the real clock and
            // would ignore the date this was asked about.
            return interval.start > now && calendar.isDate(interval.start, inSameDayAs: now)
        }
    }
}
