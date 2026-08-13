import Foundation

enum CalendarScale: String, CaseIterable, Identifiable, Hashable {
    case day, threeDay, week

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "Day"
        case .threeDay: "3 Days"
        case .week: "Week"
        }
    }

    var dayCount: Int {
        switch self {
        case .day: 1
        case .threeDay: 3
        case .week: 7
        }
    }

    /// Days shown for a given anchor. Week snaps to the week containing the
    /// anchor; the others simply start at the anchor.
    func days(anchoredAt anchor: Date, calendar: Calendar = .current) -> [Date] {
        let start: Date
        if self == .week {
            var weekCalendar = calendar
            weekCalendar.firstWeekday = 2   // Monday (SPEC.md §5.5)
            start = weekCalendar.dateInterval(of: .weekOfYear, for: anchor)?.start
                ?? calendar.startOfDay(for: anchor)
        } else {
            start = calendar.startOfDay(for: anchor)
        }
        return (0..<dayCount).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// How far ⌥←/⌥→ moves.
    var strideDays: Int { self == .week ? 7 : dayCount }
}

/// Something occupying time in the grid: a block that was planned, or a session
/// that was recorded.
///
/// Both go through one layout pass. Recorded time used to have a narrow lane of
/// its own, to stop a planned block halving in width the moment a timer
/// started — but a lane wide enough not to reflow the plan was too narrow to
/// read, which defeats the point of keeping a record at all. Two things really
/// do occupy that hour; a calendar showing them side by side is the honest
/// picture, and it is what every other calendar does with an overlap.
struct GridEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        case planned(ScheduledBlock)
        case tracked(TrackedSession)
    }

    var kind: Kind
    /// Resolved when the entry is built: a running session's end is "now",
    /// which the layout must not have to know about.
    var interval: DateInterval
    var isAllDay: Bool = false

    var id: String {
        switch kind {
        case .planned(let block): "b\(block.id)"
        case .tracked(let session): "s\(session.id)"
        }
    }

    init(kind: Kind, interval: DateInterval, isAllDay: Bool = false) {
        self.kind = kind
        self.interval = interval
        self.isAllDay = isAllDay
    }

    init(planned block: ScheduledBlock) {
        self.init(kind: .planned(block), interval: block.interval, isAllDay: block.block.isAllDay)
    }

    /// A running session ends "now", so the caller resolves the interval from
    /// the same clock every other view reads.
    init?(tracked session: TrackedSession, now: Date) {
        guard let interval = session.interval(now: now) else { return nil }
        self.init(kind: .tracked(session), interval: interval)
    }

    var plannedBlock: ScheduledBlock? {
        if case .planned(let block) = kind { return block }
        return nil
    }

    var trackedSession: TrackedSession? {
        if case .tracked(let session) = kind { return session }
        return nil
    }
}

/// An entry placed in the grid: which day column it belongs to, and where it
/// sits horizontally when it overlaps its neighbours.
struct PositionedEntry: Identifiable, Hashable {
    var entry: GridEntry
    var dayIndex: Int
    var column: Int
    var columnCount: Int
    /// How many columns wide. An entry only shares width with entries it really
    /// overlaps, so a short one beside a tall one still uses the free space.
    var span: Int = 1

    var id: String { entry.id }
}

/// The planned-only view of the same thing, kept for callers that only deal in
/// blocks.
struct PositionedBlock: Identifiable, Hashable {
    var block: ScheduledBlock
    var dayIndex: Int
    var column: Int
    var columnCount: Int
    var span: Int = 1

    var id: String { block.id }
}

enum CalendarLayout {

    /// Assigns overlapping entries to side-by-side columns, one day at a time.
    ///
    /// Entries are clustered transitively (A overlaps B, B overlaps C → one
    /// cluster of three), then greedily packed into the lowest free column.
    /// Everything in a cluster shares the same `columnCount`, so their widths
    /// line up.
    static func position(
        _ entries: [GridEntry],
        days: [Date],
        calendar: Calendar = .current
    ) -> [PositionedEntry] {
        var result: [PositionedEntry] = []

        for (dayIndex, day) in days.enumerated() {
            let dayEntries = entries
                .filter { calendar.isDate($0.interval.start, inSameDayAs: day) && !$0.isAllDay }
                .sorted { lhs, rhs in
                    lhs.interval.start != rhs.interval.start
                        ? lhs.interval.start < rhs.interval.start
                        : lhs.interval.end > rhs.interval.end
                }

            for cluster in clusters(of: dayEntries) {
                var columnEnds: [Date] = []
                var assignments: [(GridEntry, Int)] = []

                for item in cluster {
                    // Lowest column whose last entry has already finished.
                    let column = columnEnds.firstIndex { $0 <= item.interval.start }
                    if let column {
                        columnEnds[column] = item.interval.end
                        assignments.append((item, column))
                    } else {
                        columnEnds.append(item.interval.end)
                        assignments.append((item, columnEnds.count - 1))
                    }
                }

                for (item, column) in assignments {
                    result.append(PositionedEntry(
                        entry: item,
                        dayIndex: dayIndex,
                        column: column,
                        columnCount: columnEnds.count,
                        span: span(
                            for: item,
                            from: column,
                            of: columnEnds.count,
                            in: assignments
                        )
                    ))
                }
            }
        }
        return result
    }

    /// The same, for callers that only have planned blocks.
    static func position(
        _ blocks: [ScheduledBlock],
        days: [Date],
        calendar: Calendar = .current
    ) -> [PositionedBlock] {
        position(blocks.map(GridEntry.init(planned:)), days: days, calendar: calendar)
            .compactMap { positioned in
                guard let block = positioned.entry.plannedBlock else { return nil }
                return PositionedBlock(
                    block: block,
                    dayIndex: positioned.dayIndex,
                    column: positioned.column,
                    columnCount: positioned.columnCount,
                    span: positioned.span
                )
            }
    }

    /// Widens an entry rightwards across columns whose entries do not overlap it.
    private static func span(
        for item: GridEntry,
        from column: Int,
        of columnCount: Int,
        in assignments: [(GridEntry, Int)]
    ) -> Int {
        var span = 1
        var next = column + 1
        while next < columnCount {
            let blocked = assignments.contains { other, otherColumn in
                // `overlaps`, not `intersects`: one ending exactly where the
                // next begins is a tidy back-to-back pair, not a clash.
                otherColumn == next && other.interval.overlaps(item.interval)
            }
            if blocked { break }
            span += 1
            next += 1
        }
        return span
    }

    /// Groups entries into runs that transitively overlap.
    private static func clusters(of entries: [GridEntry]) -> [[GridEntry]] {
        var clusters: [[GridEntry]] = []
        var current: [GridEntry] = []
        var clusterEnd: Date?

        for item in entries {
            if let end = clusterEnd, item.interval.start < end {
                current.append(item)
                clusterEnd = max(end, item.interval.end)
            } else {
                if !current.isEmpty { clusters.append(current) }
                current = [item]
                clusterEnd = item.interval.end
            }
        }
        if !current.isEmpty { clusters.append(current) }
        return clusters
    }

    /// Side-by-side columns for anything with an interval, without the span
    /// widening `position` does. Used by the recorded-time lane, where the
    /// available width is fixed and a run of overlapping items only has to
    /// stop covering each other.
    static func pack<T>(
        _ items: [T],
        interval: (T) -> DateInterval
    ) -> [(item: T, column: Int, columnCount: Int)] {
        let sorted = items.sorted { interval($0).start < interval($1).start }
        var result: [(T, Int, Int)] = []

        var cluster: [T] = []
        var clusterEnd: Date?

        func flush() {
            guard !cluster.isEmpty else { return }
            var columnEnds: [Date] = []
            var assigned: [(T, Int)] = []
            for item in cluster {
                let slot = columnEnds.firstIndex { $0 <= interval(item).start }
                if let slot {
                    columnEnds[slot] = interval(item).end
                    assigned.append((item, slot))
                } else {
                    columnEnds.append(interval(item).end)
                    assigned.append((item, columnEnds.count - 1))
                }
            }
            result.append(contentsOf: assigned.map { ($0.0, $0.1, columnEnds.count) })
            cluster = []
            clusterEnd = nil
        }

        for item in sorted {
            if let end = clusterEnd, interval(item).start < end {
                cluster.append(item)
                clusterEnd = max(end, interval(item).end)
            } else {
                flush()
                cluster = [item]
                clusterEnd = interval(item).end
            }
        }
        flush()
        return result
    }

    /// Rounds `date` to the nearest `minutes` boundary within its own day.
    static func snap(_ date: Date, to minutes: Int, calendar: Calendar = .current) -> Date {
        guard minutes > 1 else { return date }
        let startOfDay = calendar.startOfDay(for: date)
        let elapsed = date.timeIntervalSince(startOfDay)
        let step = TimeInterval(minutes * 60)
        return startOfDay.addingTimeInterval((elapsed / step).rounded() * step)
    }
}
