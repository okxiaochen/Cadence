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

/// A block placed in the grid: which day column it belongs to, and where it
/// sits horizontally when it overlaps its neighbours.
struct PositionedBlock: Identifiable, Hashable {
    var block: ScheduledBlock
    var dayIndex: Int
    var column: Int
    var columnCount: Int
    /// How many columns wide. A block only shares width with blocks it really
    /// overlaps, so a short one beside a tall one still uses the free space.
    var span: Int = 1

    var id: String { block.id }
}

enum CalendarLayout {

    /// Assigns overlapping blocks to side-by-side columns, one day at a time.
    ///
    /// Blocks are clustered transitively (A overlaps B, B overlaps C → one
    /// cluster of three), then greedily packed into the lowest free column.
    /// Everything in a cluster shares the same `columnCount`, so their widths
    /// line up.
    static func position(
        _ blocks: [ScheduledBlock],
        days: [Date],
        calendar: Calendar = .current
    ) -> [PositionedBlock] {
        var result: [PositionedBlock] = []

        for (dayIndex, day) in days.enumerated() {
            let dayBlocks = blocks
                .filter { calendar.isDate($0.block.startAt, inSameDayAs: day) && !$0.block.isAllDay }
                .sorted { lhs, rhs in
                    lhs.block.startAt != rhs.block.startAt
                        ? lhs.block.startAt < rhs.block.startAt
                        : lhs.block.endAt > rhs.block.endAt
                }

            for cluster in clusters(of: dayBlocks) {
                var columnEnds: [Date] = []
                var assignments: [(ScheduledBlock, Int)] = []

                for item in cluster {
                    // Lowest column whose last block has already finished.
                    let column = columnEnds.firstIndex { $0 <= item.block.startAt }
                    if let column {
                        columnEnds[column] = item.block.endAt
                        assignments.append((item, column))
                    } else {
                        columnEnds.append(item.block.endAt)
                        assignments.append((item, columnEnds.count - 1))
                    }
                }

                for (item, column) in assignments {
                    result.append(PositionedBlock(
                        block: item,
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

    /// Widens a block rightwards across columns whose blocks do not overlap it.
    private static func span(
        for item: ScheduledBlock,
        from column: Int,
        of columnCount: Int,
        in assignments: [(ScheduledBlock, Int)]
    ) -> Int {
        var span = 1
        var next = column + 1
        while next < columnCount {
            let blocked = assignments.contains { other, otherColumn in
                otherColumn == next && other.interval.overlaps(item.interval)
            }
            if blocked { break }
            span += 1
            next += 1
        }
        return span
    }

    /// Groups blocks into runs that transitively overlap.
    private static func clusters(of blocks: [ScheduledBlock]) -> [[ScheduledBlock]] {
        var clusters: [[ScheduledBlock]] = []
        var current: [ScheduledBlock] = []
        var clusterEnd: Date?

        for item in blocks {
            if let end = clusterEnd, item.block.startAt < end {
                current.append(item)
                clusterEnd = max(end, item.block.endAt)
            } else {
                if !current.isEmpty { clusters.append(current) }
                current = [item]
                clusterEnd = item.block.endAt
            }
        }
        if !current.isEmpty { clusters.append(current) }
        return clusters
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
