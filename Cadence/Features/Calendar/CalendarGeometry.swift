import Foundation
import SwiftUI

/// Converts between grid points and dates. The grid's coordinate space starts
/// at the left edge of the first day column — the time gutter sits outside it,
/// so `x` maps straight onto a day index.
struct CalendarGeometry {
    var days: [Date]
    var dayWidth: CGFloat
    var hourHeight: CGFloat
    var calendar: Calendar = .current

    static let hoursPerDay: CGFloat = 24

    var totalHeight: CGFloat { hourHeight * Self.hoursPerDay }
    var totalWidth: CGFloat { dayWidth * CGFloat(days.count) }

    // MARK: - Date → point

    /// Vertical offset of a date within its day.
    func y(for date: Date) -> CGFloat {
        let startOfDay = calendar.startOfDay(for: date)
        let hours = date.timeIntervalSince(startOfDay) / 3600
        return CGFloat(hours) * hourHeight
    }

    /// One point is shaved off the bottom so a block ending at 11:00 and one
    /// starting at 11:00 do not share an edge and look like a single box.
    /// The old floor of 14pt made short blocks *actually* overlap the next one.
    static let blockGap: CGFloat = 1

    func height(for interval: DateInterval) -> CGFloat {
        max(3, CGFloat(interval.duration / 3600) * hourHeight - Self.blockGap)
    }

    func x(forDayIndex index: Int) -> CGFloat {
        CGFloat(index) * dayWidth
    }

    func dayIndex(of date: Date) -> Int? {
        days.firstIndex { calendar.isDate($0, inSameDayAs: date) }
    }

    /// Frame for a block, inset for its overlap column.
    func rect(
        interval: DateInterval,
        dayIndex: Int,
        column: Int,
        columnCount: Int,
        span: Int = 1,
        inset: CGFloat = 2
    ) -> CGRect {
        let usable = dayWidth - inset * 2
        let columnWidth = usable / CGFloat(max(1, columnCount))
        let width = columnWidth * CGFloat(max(1, span))
        return CGRect(
            x: x(forDayIndex: dayIndex) + inset + columnWidth * CGFloat(column),
            y: y(for: interval.start),
            width: max(12, width - (columnCount > 1 ? 2 : 0)),
            height: height(for: interval)
        )
    }

    // MARK: - Point → date

    func dayIndex(atX x: CGFloat) -> Int {
        guard dayWidth > 0 else { return 0 }
        return min(days.count - 1, max(0, Int(x / dayWidth)))
    }

    /// The date under a point, snapped to `snapMinutes`. Clamped to the day.
    func date(at point: CGPoint, snapMinutes: Int) -> Date {
        let day = days[dayIndex(atX: point.x)]
        let hours = max(0, min(Self.hoursPerDay, point.y / hourHeight))
        let raw = calendar.startOfDay(for: day).addingTimeInterval(TimeInterval(hours) * 3600)
        return CalendarLayout.snap(raw, to: snapMinutes, calendar: calendar)
    }

    /// A time on a *specific* day from a vertical position alone.
    ///
    /// Resizing uses this rather than `date(at:)`: dragging an edge sideways
    /// must not move that edge to another day column, which would leave a block
    /// whose start and end are on different days.
    func date(onDay day: Date, atY y: CGFloat, snapMinutes: Int) -> Date {
        let hours = max(0, min(Self.hoursPerDay, y / hourHeight))
        let raw = calendar.startOfDay(for: day).addingTimeInterval(TimeInterval(hours) * 3600)
        return CalendarLayout.snap(raw, to: snapMinutes, calendar: calendar)
    }

    /// Moves `interval` so it starts on the given day at the given time, keeping
    /// its duration and never spilling past midnight.
    func reposition(_ interval: DateInterval, toStart start: Date) -> DateInterval {
        let duration = interval.duration
        let endOfDay = calendar.startOfDay(for: start).addingTimeInterval(86_400)
        let clampedStart = min(start, endOfDay.addingTimeInterval(-duration))
        return DateInterval(start: clampedStart, end: clampedStart.addingTimeInterval(duration))
    }
}
