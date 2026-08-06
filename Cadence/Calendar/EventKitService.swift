import EventKit
import Foundation
import Observation

/// A calendar event from the system, flattened to what the grid needs.
/// Never persisted — Apple Calendar is read-only for us (SPEC.md §2).
struct BusyEvent: Identifiable, Hashable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendarID: String
    var calendarTitle: String
    var colorHex: String

    var interval: DateInterval { DateInterval(start: start, end: min(end, start.addingTimeInterval(86_400 * 2))) }
}

struct CalendarSource: Identifiable, Hashable {
    var id: String
    var title: String
    var colorHex: String
}

/// Read-only EventKit access: authorization, a busy-event fetch for a date
/// range, and a refresh when the system store changes underneath us.
@MainActor
@Observable
final class EventKitService {
    enum Access: Equatable {
        case unknown, denied, authorized
    }

    /// Our own published calendar, excluded from the busy overlay.
    var managedCalendarID: String?

    private(set) var access: Access = .unknown
    private(set) var events: [BusyEvent] = []
    private(set) var sources: [CalendarSource] = []

    let store = EKEventStore()
    /// Written once on the main actor in `init` and only read from `deinit`,
    /// which is nonisolated — hence the opt-out.
    private nonisolated(unsafe) var observer: NSObjectProtocol?
    private var lastRange: DateInterval?

    init() {
        refreshAuthorization()
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func refreshAuthorization() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .authorized
        case .denied, .restricted: access = .denied
        default: access = .unknown
        }
    }

    /// Prompts on first call. Safe to call repeatedly.
    func requestAccess() async {
        do {
            let granted = try await store.requestFullAccessToEvents()
            access = granted ? .authorized : .denied
        } catch {
            access = .denied
        }
        if access == .authorized {
            loadSources()
            reload()
        }
    }

    func loadSources() {
        guard access == .authorized else { return }
        sources = store.calendars(for: .event)
            .filter { $0.calendarIdentifier != managedCalendarID }
            .map { calendar in
                CalendarSource(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    colorHex: Self.hex(from: calendar.cgColor)
                )
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Fetches busy events for `range`, skipping calendars the user hid.
    func load(range: DateInterval, hiddenCalendarIDs: Set<String>) {
        lastRange = range
        guard access == .authorized else {
            events = []
            return
        }
        if sources.isEmpty { loadSources() }

        let calendars = store.calendars(for: .event)
            .filter { !hiddenCalendarIDs.contains($0.calendarIdentifier) }
            // Our own events are already known to us as blocks; counting them
            // again would make every scheduled task conflict with itself.
            .filter { $0.calendarIdentifier != managedCalendarID }
        guard !calendars.isEmpty else {
            events = []
            return
        }

        let predicate = store.predicateForEvents(
            withStart: range.start,
            end: range.end,
            calendars: calendars
        )
        events = store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .map { event in
                BusyEvent(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "Busy",
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    calendarID: event.calendar.calendarIdentifier,
                    calendarTitle: event.calendar.title,
                    colorHex: Self.hex(from: event.calendar.cgColor)
                )
            }
            .sorted { $0.start < $1.start }
    }

    private func reload() {
        guard let lastRange else { return }
        load(range: lastRange, hiddenCalendarIDs: Preferences.shared.hiddenCalendarIDs)
    }

    /// Timed events only — all-day events are shown in the top lane but do not
    /// make the whole day unavailable.
    var busyIntervals: [DateInterval] {
        FreeBusy.merge(
            events
                .filter { !$0.isAllDay && $0.end > $0.start }
                .map { DateInterval(start: $0.start, end: $0.end) }
        )
    }

    private static func hex(from color: CGColor?) -> String {
        guard let components = color?.components, components.count >= 3 else { return "#8E8E93" }
        let r = Int((components[0] * 255).rounded())
        let g = Int((components[1] * 255).rounded())
        let b = Int((components[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
