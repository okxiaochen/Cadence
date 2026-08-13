import EventKit
import Foundation
import GRDB
import Observation

/// One-way publish of time blocks into a dedicated "Cadence" calendar.
///
/// **This calendar cannot be made read-only.** EventKit exposes
/// `allowsContentModifications` as a read-only property reflecting what the
/// *source* permits; there is no API to lock a writable local calendar. So the
/// database stays the single source of truth and every reconcile overwrites the
/// calendar — an edit made in Calendar.app survives only until the next sync.
///
/// The events we publish are excluded from the busy overlay. Without that, every
/// scheduled task would appear to collide with itself and the AI would refuse to
/// place anything (SPEC.md §7).
@MainActor
@Observable
final class CalendarSyncService {

    static let calendarTitle = "Cadence"

    /// How far around today we keep the calendar in step. Blocks outside this
    /// window are not published; the reconcile would otherwise walk the
    /// entire history on every write.
    static let windowPast: Int = -30
    static let windowFuture: Int = 180

    private let store: EKEventStore
    private let database: AppDatabase

    private(set) var lastError: String?
    private(set) var lastSyncedAt: Date?

    init(store: EKEventStore, database: AppDatabase) {
        self.store = store
        self.database = database
        self.managedCalendarID = UserDefaults.standard.string(forKey: Key.calendarID)
        self.isEnabled = UserDefaults.standard.bool(forKey: Key.enabled)
        self.publishesTrackedTime = UserDefaults.standard.bool(forKey: Key.publishesTracked)
    }

    /// The identifier of our calendar, if it exists. Read by the busy overlay
    /// so our own events never count as external commitments.
    var managedCalendarID: String? {
        didSet { UserDefaults.standard.set(managedCalendarID, forKey: Key.calendarID) }
    }

    /// Observable rather than a computed `UserDefaults` accessor: a plain
    /// computed property means the Settings toggle changes a default that no
    /// view is watching, so the UI never updates and the switch appears dead.
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Key.enabled) }
    }

    /// Whether recorded sessions go to the calendar as well as planned blocks.
    /// Off by default: publishing what you *did* to a calendar other people may
    /// see is a decision only the user can make.
    var publishesTrackedTime: Bool {
        didSet { UserDefaults.standard.set(publishesTrackedTime, forKey: Key.publishesTracked) }
    }

    private enum Key {
        static let calendarID = "managedCalendarID"
        static let enabled = "calendarWriteBackEnabled"
        static let publishesTracked = "calendarPublishesTrackedTime"
    }

    // MARK: - Calendar

    /// Finds or creates the Cadence calendar. Prefers a local source so nothing
    /// is published to a shared or subscribed account by accident.
    @discardableResult
    func ensureCalendar() throws -> EKCalendar {
        if let id = managedCalendarID, let existing = store.calendar(withIdentifier: id) {
            return existing
        }
        if let found = store.calendars(for: .event).first(where: { $0.title == Self.calendarTitle }) {
            managedCalendarID = found.calendarIdentifier
            return found
        }

        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = Self.calendarTitle
        calendar.source = preferredSource()
        guard calendar.source != nil else { throw SyncError.noWritableSource }

        try store.saveCalendar(calendar, commit: true)
        managedCalendarID = calendar.calendarIdentifier
        return calendar
    }

    private func preferredSource() -> EKSource? {
        let sources = store.sources
        return sources.first { $0.sourceType == .local }
            ?? sources.first { $0.sourceType == .calDAV && $0.title == "iCloud" }
            ?? store.defaultCalendarForNewEvents?.source
            ?? sources.first
    }

    func removeManagedCalendar() throws {
        guard let id = managedCalendarID, let calendar = store.calendar(withIdentifier: id) else {
            managedCalendarID = nil
            return
        }
        try store.removeCalendar(calendar, commit: true)
        managedCalendarID = nil
        try database.writer.write { db in
            try db.execute(sql: "UPDATE time_block SET externalEventID = NULL")
            try db.execute(sql: "UPDATE progress_entry SET externalEventID = NULL")
        }
    }

    // MARK: - Reconcile

    struct Report: Equatable {
        var created = 0
        var updated = 0
        var deleted = 0

        var isEmpty: Bool { created == 0 && updated == 0 && deleted == 0 }
    }

    /// Makes the calendar match the database for the sync window. Idempotent:
    /// running it twice in a row does nothing the second time.
    @discardableResult
    func reconcile(now: Date = Date()) -> Report {
        guard isEnabled else { return Report() }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            lastError = "Cadence needs calendar access to publish your blocks."
            return Report()
        }
        lastError = nil

        do {
            let calendar = try ensureCalendar()
            let window = syncWindow(now: now)

            let blocks = try database.writer.read { db in
                try TodoRepository.scheduledBlocks(db, in: window)
            }

            // Everything we previously published inside the window.
            let predicate = store.predicateForEvents(
                withStart: window.start, end: window.end, calendars: [calendar]
            )
            var existing = Dictionary(
                grouping: store.events(matching: predicate),
                by: { $0.eventIdentifier ?? UUID().uuidString }
            ).compactMapValues(\.first)

            var report = Report()
            var idFixes: [(blockID: String, eventID: String?)] = []

            for scheduled in blocks {
                let block = scheduled.block
                let event = block.externalEventID.flatMap { existing[$0] }

                if let event {
                    existing.removeValue(forKey: block.externalEventID!)
                    if apply(scheduled, to: event) {
                        try store.save(event, span: .thisEvent, commit: false)
                        report.updated += 1
                    }
                } else {
                    let fresh = EKEvent(eventStore: store)
                    fresh.calendar = calendar
                    _ = apply(scheduled, to: fresh)
                    try store.save(fresh, span: .thisEvent, commit: false)
                    idFixes.append((block.id, fresh.eventIdentifier))
                    report.created += 1
                }
            }

            // Time actually spent, when the user asked for it to be published.
            // Running sessions are skipped: an event whose end moves every
            // minute would rewrite the calendar all day.
            var sessionIDFixes: [(entryID: String, eventID: String?)] = []
            if publishesTrackedTime {
                let sessions = try database.writer.read { db in
                    try ProgressRepository.sessions(db, in: window)
                }.filter { !$0.entry.isRunning }

                for session in sessions {
                    guard let interval = session.interval() else { continue }
                    let event = session.entry.externalEventID.flatMap { existing[$0] }

                    if let event {
                        existing.removeValue(forKey: session.entry.externalEventID!)
                        if apply(session, interval: interval, to: event) {
                            try store.save(event, span: .thisEvent, commit: false)
                            report.updated += 1
                        }
                    } else {
                        let fresh = EKEvent(eventStore: store)
                        fresh.calendar = calendar
                        _ = apply(session, interval: interval, to: fresh)
                        try store.save(fresh, span: .thisEvent, commit: false)
                        sessionIDFixes.append((session.entry.id, fresh.eventIdentifier))
                        report.created += 1
                    }
                }
            }

            // Anything left over no longer exists in the database. Note that
            // sessions are only matched above when publishing is on, so
            // switching it off sweeps every published session away here.
            for (_, orphan) in existing {
                try store.remove(orphan, span: .thisEvent, commit: false)
                report.deleted += 1
            }

            if !report.isEmpty { try store.commit() }

            if !idFixes.isEmpty || !sessionIDFixes.isEmpty {
                try database.writer.write { db in
                    for fix in idFixes {
                        try db.execute(
                            sql: "UPDATE time_block SET externalEventID = ? WHERE id = ?",
                            arguments: [fix.eventID, fix.blockID]
                        )
                    }
                    for fix in sessionIDFixes {
                        try db.execute(
                            sql: "UPDATE progress_entry SET externalEventID = ? WHERE id = ?",
                            arguments: [fix.eventID, fix.entryID]
                        )
                    }
                }
            }

            lastSyncedAt = Date()
            return report

        } catch {
            lastError = error.localizedDescription
            return Report()
        }
    }

    /// Returns true when something actually changed, so unchanged events are
    /// not rewritten (each save fires a store-changed notification).
    private func apply(_ scheduled: ScheduledBlock, to event: EKEvent) -> Bool {
        let title = scheduled.todo.title
        let notes = noteBody(for: scheduled)
        var changed = false

        if event.title != title { event.title = title; changed = true }
        if event.startDate != scheduled.block.startAt {
            event.startDate = scheduled.block.startAt
            changed = true
        }
        if event.endDate != scheduled.block.endAt {
            event.endDate = scheduled.block.endAt
            changed = true
        }
        if event.notes != notes { event.notes = notes; changed = true }
        return changed
    }

    /// A recorded session as an event. Titled so a glance at the week in
    /// Calendar.app distinguishes what was planned from what happened.
    private func apply(_ session: TrackedSession, interval: DateInterval, to event: EKEvent) -> Bool {
        let title = "✓ \(session.todo.title)"
        var lines: [String] = ["Time tracked in Cadence."]
        if let project = session.project { lines.append("Project: \(project.name)") }
        if !session.entry.note.isEmpty { lines.append(session.entry.note) }
        let notes = lines.joined(separator: "\n")

        var changed = false
        if event.title != title { event.title = title; changed = true }
        if event.startDate != interval.start { event.startDate = interval.start; changed = true }
        if event.endDate != interval.end { event.endDate = interval.end; changed = true }
        if event.notes != notes { event.notes = notes; changed = true }
        return changed
    }

    private func noteBody(for scheduled: ScheduledBlock) -> String {
        var lines: [String] = []
        if let project = scheduled.project { lines.append("Project: \(project.name)") }
        if !scheduled.todo.notes.isEmpty { lines.append(scheduled.todo.notes) }
        lines.append("")
        lines.append("Managed by Cadence — edits here are overwritten on the next sync.")
        return lines.joined(separator: "\n")
    }

    func syncWindow(now: Date = Date()) -> DateInterval {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: Self.windowPast, to: calendar.startOfDay(for: now))
            ?? now
        let end = calendar.date(byAdding: .day, value: Self.windowFuture, to: start) ?? now
        return DateInterval(start: start, end: end)
    }

    enum SyncError: LocalizedError {
        case noWritableSource

        var errorDescription: String? {
            switch self {
            case .noWritableSource:
                "No writable calendar account was found to create the Cadence calendar in."
            }
        }
    }
}
