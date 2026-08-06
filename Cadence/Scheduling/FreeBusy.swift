import Foundation

/// Deterministic interval maths over busy time. The calendar uses this to shade
/// the grid; in M3 `find_free_slots` is built on top of it, and the model never
/// does this arithmetic itself (SPEC.md §7, AI-INTEGRATION.md §4).
enum FreeBusy {

    /// Merges overlapping and touching intervals into a minimal sorted set.
    static func merge(_ intervals: [DateInterval]) -> [DateInterval] {
        let sorted = intervals
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        guard var current = sorted.first else { return [] }

        var merged: [DateInterval] = []
        for interval in sorted.dropFirst() {
            if interval.start <= current.end {
                current.end = max(current.end, interval.end)
            } else {
                merged.append(current)
                current = interval
            }
        }
        merged.append(current)
        return merged
    }

    /// Everything inside `window` that `busy` does not cover.
    static func gaps(in window: DateInterval, busy: [DateInterval]) -> [DateInterval] {
        let clipped = merge(busy).compactMap { $0.intersection(with: window) }
        var free: [DateInterval] = []
        var cursor = window.start

        for interval in clipped {
            if interval.start > cursor {
                free.append(DateInterval(start: cursor, end: interval.start))
            }
            cursor = max(cursor, interval.end)
        }
        if cursor < window.end {
            free.append(DateInterval(start: cursor, end: window.end))
        }
        return free.filter { $0.duration > 0 }
    }

    /// Free windows of at least `minimumMinutes`, across several windows.
    static func openings(
        in windows: [DateInterval],
        busy: [DateInterval],
        minimumMinutes: Int
    ) -> [DateInterval] {
        let minimum = TimeInterval(minimumMinutes * 60)
        return windows
            .flatMap { gaps(in: $0, busy: busy) }
            .filter { $0.duration >= minimum }
            .sorted { $0.start < $1.start }
    }

    /// True when `candidate` overlaps anything busy. Used to validate a drop
    /// before it is written, and every AI-proposed block in M3.
    static func conflicts(_ candidate: DateInterval, with busy: [DateInterval]) -> Bool {
        busy.contains { $0.intersects(candidate) && ($0.intersection(with: candidate)?.duration ?? 0) > 0 }
    }
}

extension DateInterval {
    /// `intersects` alone reports true for intervals that merely touch.
    func overlaps(_ other: DateInterval) -> Bool {
        start < other.end && other.start < end
    }
}
