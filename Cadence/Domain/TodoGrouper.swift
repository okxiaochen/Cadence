import Foundation

/// Turns a flat list of rows into the sections the list view renders. Grouping
/// and sorting live here rather than in SQL, because grouping by tag puts one
/// task into several sections — which SQL would have to duplicate rows to do.
enum TodoGrouper {

    static func sections(
        rows: [TodoDetail],
        query: TodoQuery,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [TodoSection] {
        let sorted = sort(rows, by: query.sort)

        switch query.resolvedGrouping {
        case .none:
            return [TodoSection(id: "all", title: "", symbolName: nil, colorHex: nil, items: sorted)]

        case .project:
            var byProject: [String: [TodoDetail]] = [:]
            var unassigned: [TodoDetail] = []
            for row in sorted {
                if let project = row.project {
                    byProject[project.id, default: []].append(row)
                } else {
                    unassigned.append(row)
                }
            }
            var sections = byProject
                .compactMap { id, items -> TodoSection? in
                    guard let project = items.first?.project else { return nil }
                    return TodoSection(
                        id: id,
                        title: project.name,
                        symbolName: project.symbolName,
                        colorHex: project.colorHex,
                        items: items
                    )
                }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            if !unassigned.isEmpty {
                sections.append(TodoSection(
                    id: "no-project", title: "No Project", symbolName: "tray",
                    colorHex: nil, items: unassigned
                ))
            }
            return sections

        case .tag:
            var byTag: [String: (tag: Tag, items: [TodoDetail])] = [:]
            var untagged: [TodoDetail] = []
            for row in sorted {
                if row.tags.isEmpty {
                    untagged.append(row)
                } else {
                    for tag in row.tags {
                        byTag[tag.id, default: (tag, [])].items.append(row)
                    }
                }
            }
            var sections = byTag.values
                .map { TodoSection(
                    id: $0.tag.id, title: "#\($0.tag.name)", symbolName: nil,
                    colorHex: $0.tag.colorHex, items: $0.items
                ) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            if !untagged.isEmpty {
                sections.append(TodoSection(
                    id: "no-tag", title: "Untagged", symbolName: nil,
                    colorHex: nil, items: untagged
                ))
            }
            return sections

        case .day:
            var grouped: [DayBucket: [TodoDetail]] = [:]
            for row in sorted {
                grouped[DayBucket(for: row.scheduleDate, now: now, calendar: calendar), default: []]
                    .append(row)
            }

            // The next week of days is always laid out, empty or not, the way
            // Reminders does — an empty day is a place to add something.
            var buckets = Set(grouped.keys)
            let startOfToday = calendar.startOfDay(for: now)
            for offset in 0...DayBucket.namedDayHorizon {
                if let day = calendar.date(byAdding: .day, value: offset, to: startOfToday) {
                    buckets.insert(.day(day))
                }
            }
            buckets.insert(.laterThisMonth)

            return buckets
                .map { bucket in
                    TodoSection(
                        id: bucket.id,
                        title: bucket.title(now: now, calendar: calendar),
                        symbolName: bucket.symbolName,
                        colorHex: nil,
                        items: grouped[bucket] ?? [],
                        sortKey: bucket.sortKey,
                        date: bucket.date,
                        acceptsQuickAdd: bucket.acceptsQuickAdd
                    )
                }
                // A skeleton day stays; an empty Past Due or month bucket does not.
                .filter { !$0.items.isEmpty || $0.acceptsQuickAdd }
                .sorted { $0.sortKey < $1.sortKey }

        case .dueDate:
            let buckets = DueBucket.allCases
            var grouped: [DueBucket: [TodoDetail]] = [:]
            for row in sorted {
                grouped[DueBucket(for: row.todo.dueAt, now: now, calendar: calendar), default: []].append(row)
            }
            return buckets.compactMap { bucket in
                guard let items = grouped[bucket], !items.isEmpty else { return nil }
                return TodoSection(
                    id: bucket.rawValue, title: bucket.title,
                    symbolName: bucket.symbolName, colorHex: nil, items: items
                )
            }
        }
    }

    static func sort(_ rows: [TodoDetail], by sort: TodoSort) -> [TodoDetail] {
        switch sort {
        case .manual:
            return rows.sorted { $0.todo.sortOrder < $1.todo.sortOrder }
        case .created:
            return rows.sorted { $0.todo.createdAt > $1.todo.createdAt }
        case .priority:
            return rows.sorted {
                $0.todo.priority.rawValue != $1.todo.priority.rawValue
                    ? $0.todo.priority.rawValue > $1.todo.priority.rawValue
                    : $0.todo.sortOrder < $1.todo.sortOrder
            }
        case .dueDate:
            // Undated tasks sink to the bottom rather than sorting as "oldest".
            return rows.sorted {
                switch ($0.todo.dueAt, $1.todo.dueAt) {
                case let (lhs?, rhs?): lhs != rhs ? lhs < rhs : $0.todo.sortOrder < $1.todo.sortOrder
                case (nil, _?): false
                case (_?, nil): true
                case (nil, nil): $0.todo.sortOrder < $1.todo.sortOrder
                }
            }
        }
    }
}

enum DueBucket: String, CaseIterable {
    case overdue, today, tomorrow, thisWeek, later, none

    init(for date: Date?, now: Date, calendar: Calendar) {
        guard let date else { self = .none; return }
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
              let startOfDayAfter = calendar.date(byAdding: .day, value: 2, to: startOfToday),
              let endOfWeek = calendar.date(byAdding: .day, value: 7, to: startOfToday)
        else { self = .none; return }

        if date < startOfToday { self = .overdue }
        else if date < startOfTomorrow { self = .today }
        else if date < startOfDayAfter { self = .tomorrow }
        else if date < endOfWeek { self = .thisWeek }
        else { self = .later }
    }

    var title: String {
        switch self {
        case .overdue: "Overdue"
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .thisWeek: "This Week"
        case .later: "Later"
        case .none: "No Due Date"
        }
    }

    var symbolName: String? {
        switch self {
        case .overdue: "exclamationmark.triangle"
        case .today: "star"
        case .tomorrow: "sunrise"
        case .thisWeek: "calendar"
        case .later: "calendar.badge.clock"
        case .none: nil
        }
    }
}

/// One section per day, the way Apple Reminders lays out a schedule:
/// Past Due, Today, Tomorrow, then each named day, then coarser buckets.
enum DayBucket: Hashable {
    case pastDue
    case day(Date)
    case laterThisMonth
    case month(Date)
    case none

    /// Days further out than this collapse into month buckets.
    static let namedDayHorizon = 7

    init(for date: Date?, now: Date, calendar: Calendar) {
        guard let date else { self = .none; return }
        let startOfToday = calendar.startOfDay(for: now)
        let startOfDue = calendar.startOfDay(for: date)

        if startOfDue < startOfToday { self = .pastDue; return }

        let days = calendar.dateComponents([.day], from: startOfToday, to: startOfDue).day ?? 0
        if days <= Self.namedDayHorizon { self = .day(startOfDue); return }

        if calendar.isDate(startOfDue, equalTo: startOfToday, toGranularity: .month) {
            self = .laterThisMonth
        } else {
            self = .month(calendar.dateInterval(of: .month, for: startOfDue)?.start ?? startOfDue)
        }
    }

    var id: String {
        switch self {
        case .pastDue: "past-due"
        case .day(let date): "day-\(ISO.string(date))"
        case .laterThisMonth: "later-this-month"
        case .month(let date): "month-\(ISO.string(date))"
        case .none: "no-date"
        }
    }

    func title(now: Date = Date(), calendar: Calendar = .current) -> String {
        switch self {
        case .pastDue:
            return "Past Due"
        case .day(let date):
            let startOfToday = calendar.startOfDay(for: now)
            let days = calendar.dateComponents([.day], from: startOfToday, to: date).day ?? 0
            switch days {
            case 0: return "Today"
            case 1: return "Tomorrow"
            default: return Self.format(date, "EEE, MMM d", calendar: calendar)
            }
        case .laterThisMonth:
            return "Rest of \(Self.format(now, "MMMM", calendar: calendar))"
        case .month(let date):
            return Self.format(date, "MMMM yyyy", calendar: calendar)
        case .none:
            return "No Due Date"
        }
    }

    /// Formats in the *bucketing* calendar's timezone. `Date.formatted` uses the
    /// system zone, which can label the 1st of a month with the previous month
    /// whenever the two disagree.
    private static func format(_ date: Date, _ template: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    var symbolName: String? {
        switch self {
        case .pastDue: "exclamationmark.triangle"
        case .day, .laterThisMonth, .month: nil
        case .none: nil
        }
    }

    /// The date a task added here should get.
    var date: Date? {
        switch self {
        case .day(let date): date
        case .laterThisMonth, .month, .pastDue, .none: nil
        }
    }

    /// Only real days offer inline adding — "Past Due" and "No Due Date" are
    /// outcomes, not places you would deliberately file something.
    var acceptsQuickAdd: Bool {
        switch self {
        case .day, .laterThisMonth: true
        case .pastDue, .month, .none: false
        }
    }

    /// Sections are ordered chronologically, with undated work last.
    var sortKey: Double {
        switch self {
        case .pastDue: -1
        case .day(let date): date.timeIntervalSince1970
        case .laterThisMonth: Date.distantFuture.timeIntervalSince1970 - 3
        case .month(let date): date.timeIntervalSince1970
        case .none: Date.distantFuture.timeIntervalSince1970
        }
    }
}
