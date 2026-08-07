import AppKit
import Foundation
import Observation
import UserNotifications

/// Local reminders for scheduled work.
///
/// Everything is rebuilt from the agenda rather than tracked incrementally:
/// blocks move constantly, and a diffing scheme that drifts leaves people with
/// alerts for work they already rescheduled. Removing all pending requests and
/// re-adding them is cheap and cannot go stale.
@MainActor
@Observable
final class NotificationService: NSObject {

    enum Authorization: Equatable {
        case unknown, denied, authorized
    }

    private(set) var authorization: Authorization = .unknown

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Key.enabled) }
    }

    /// Minutes before a block starts to warn. Zero means only at the start.
    var leadTimeMinutes: Int {
        didSet { UserDefaults.standard.set(leadTimeMinutes, forKey: Key.leadTime) }
    }

    private enum Key {
        static let enabled = "notificationsEnabled"
        static let leadTime = "notificationLeadTimeMinutes"
    }

    private enum Identifier {
        static let category = "cadence.block"
        static let complete = "cadence.complete"
        static let snooze = "cadence.snooze"

        static func start(_ blockID: String) -> String { "start-\(blockID)" }
        static func lead(_ blockID: String) -> String { "lead-\(blockID)" }
    }

    /// iOS and macOS both cap pending requests at 64; staying well inside it
    /// means the nearest alerts are never the ones dropped.
    private static let maxScheduled = 48

    private weak var model: AppModel?
    private let center = UNUserNotificationCenter.current()

    init(model: AppModel) {
        self.model = model
        self.isEnabled = UserDefaults.standard.object(forKey: Key.enabled) as? Bool ?? true
        self.leadTimeMinutes = UserDefaults.standard.object(forKey: Key.leadTime) as? Int ?? 5
        super.init()
        center.delegate = self
        registerCategory()
    }

    private func registerCategory() {
        let complete = UNNotificationAction(
            identifier: Identifier.complete,
            title: "Complete",
            options: []
        )
        let snooze = UNNotificationAction(
            identifier: Identifier.snooze,
            title: "Snooze 10 min",
            options: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Identifier.category,
                actions: [complete, snooze],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    // MARK: - Authorization

    func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: authorization = .authorized
        case .denied: authorization = .denied
        default: authorization = .unknown
        }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            authorization = granted ? .authorized : .denied
            return granted
        } catch {
            authorization = .denied
            return false
        }
    }

    // MARK: - Scheduling

    /// Rebuilds every pending reminder from the current agenda.
    func reschedule(from items: [AgendaItem], now: Date = Date()) async {
        center.removeAllPendingNotificationRequests()
        guard isEnabled, authorization == .authorized else { return }

        let upcoming = items
            .filter { !$0.todo.isCompleted }
            .compactMap { item -> (AgendaItem, DateInterval)? in
                guard let interval = item.interval, interval.start > now else { return nil }
                return (item, interval)
            }
            .prefix(Self.maxScheduled)

        for (item, interval) in upcoming {
            await add(
                identifier: Identifier.start(item.id),
                title: item.todo.title,
                body: "Now until \(Format.time(interval.end))",
                fireAt: interval.start,
                taskID: item.todo.id
            )

            let lead = leadTimeMinutes
            guard lead > 0 else { continue }
            let warnAt = interval.start.addingTimeInterval(TimeInterval(-lead * 60))
            guard warnAt > now else { continue }
            await add(
                identifier: Identifier.lead(item.id),
                title: "Up next: \(item.todo.title)",
                body: "Starts at \(Format.time(interval.start))",
                fireAt: warnAt,
                taskID: item.todo.id
            )
        }
    }

    private func add(
        identifier: String,
        title: String,
        body: String,
        fireAt: Date,
        taskID: String
    ) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Identifier.category
        content.userInfo = ["taskID": taskID]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireAt
        )
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
        try? await center.add(request)
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
    }
}

// MARK: - Responding

extension NotificationService: UNUserNotificationCenterDelegate {

    /// Without this, an alert for work starting *now* is silently swallowed
    /// whenever Cadence happens to be the front app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let taskID = userInfo["taskID"] as? String else { return }
        let action = response.actionIdentifier

        await MainActor.run { [weak self] in
            guard let model = self?.model else { return }
            switch action {
            case Identifier.complete:
                model.setStatus(.done, for: [taskID])
            case Identifier.snooze:
                model.snooze(taskID: taskID, byMinutes: 10)
            default:
                // Tapping the body opens the task.
                model.inspectedID = taskID
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
