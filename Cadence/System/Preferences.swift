import Foundation
import Observation

/// User settings, backed by `UserDefaults`. Small enough that a hand-rolled
/// observable beats a property-wrapper framework, and it gives the AI layer a
/// single place to read planning constraints from in M3.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        workdayStartHour = defaults.integer(forKey: Key.workdayStart, default: 9)
        workdayEndHour = defaults.integer(forKey: Key.workdayEnd, default: 18)
        includesWeekends = defaults.bool(forKey: Key.includesWeekends, default: false)
        defaultEstimateMinutes = defaults.integer(forKey: Key.defaultEstimate, default: 30)
        snapMinutes = defaults.integer(forKey: Key.snapMinutes, default: 15)
        storedHourHeight = min(200, max(24, defaults.double(forKey: Key.hourHeight, default: 48)))
        hiddenCalendarIDs = Set(defaults.stringArray(forKey: Key.hiddenCalendars) ?? [])
        backgroundStyle = BackgroundStyle(
            rawValue: defaults.string(forKey: Key.backgroundStyle) ?? ""
        ) ?? .solid
        backgroundOpacity = defaults.double(forKey: Key.backgroundOpacity, default: 0.7)
        appAppearance = AppAppearance(
            rawValue: defaults.string(forKey: Key.appearance) ?? ""
        ) ?? .system
    }

    // MARK: - Planning

    var workdayStartHour: Int { didSet { defaults.set(workdayStartHour, forKey: Key.workdayStart) } }
    var workdayEndHour: Int { didSet { defaults.set(workdayEndHour, forKey: Key.workdayEnd) } }
    var includesWeekends: Bool { didSet { defaults.set(includesWeekends, forKey: Key.includesWeekends) } }
    var defaultEstimateMinutes: Int { didSet { defaults.set(defaultEstimateMinutes, forKey: Key.defaultEstimate) } }

    // MARK: - Calendar view

    /// Drag and resize snap granularity, in minutes.
    var snapMinutes: Int { didSet { defaults.set(snapMinutes, forKey: Key.snapMinutes) } }

    /// Points per hour in the grid, clamped to a usable zoom range.
    ///
    /// Backed by a separate stored property on purpose: `@Observable` rewrites
    /// stored properties into computed ones, so clamping by re-assigning inside
    /// `didSet` would recurse into the generated setter and overflow the stack.
    var hourHeight: Double {
        get { storedHourHeight }
        set {
            storedHourHeight = min(200, max(24, newValue))
            defaults.set(storedHourHeight, forKey: Key.hourHeight)
        }
    }

    private var storedHourHeight: Double

    // MARK: - Appearance

    var backgroundStyle: BackgroundStyle {
        didSet { defaults.set(backgroundStyle.rawValue, forKey: Key.backgroundStyle) }
    }

    var backgroundOpacity: Double {
        didSet { defaults.set(backgroundOpacity, forKey: Key.backgroundOpacity) }
    }

    var appAppearance: AppAppearance {
        didSet {
            defaults.set(appAppearance.rawValue, forKey: Key.appearance)
            appAppearance.apply()
        }
    }

    var background: BackgroundAppearance {
        BackgroundAppearance(style: backgroundStyle, opacity: backgroundOpacity)
    }

    /// Calendars the user has switched off in the busy overlay.
    var hiddenCalendarIDs: Set<String> {
        didSet { defaults.set(Array(hiddenCalendarIDs), forKey: Key.hiddenCalendars) }
    }

    // MARK: - Derived

    /// The working-hours window for a given day, or nil on a non-working day.
    func workingHours(on day: Date, calendar: Calendar = .current) -> DateInterval? {
        let weekday = calendar.component(.weekday, from: day)
        let isWeekend = weekday == 1 || weekday == 7
        if isWeekend && !includesWeekends { return nil }

        let start = calendar.startOfDay(for: day)
        guard let from = calendar.date(byAdding: .hour, value: workdayStartHour, to: start),
              let to = calendar.date(byAdding: .hour, value: workdayEndHour, to: start),
              to > from
        else { return nil }
        return DateInterval(start: from, end: to)
    }

    private enum Key {
        static let workdayStart = "workdayStartHour"
        static let workdayEnd = "workdayEndHour"
        static let includesWeekends = "includesWeekends"
        static let defaultEstimate = "defaultEstimateMinutes"
        static let snapMinutes = "snapMinutes"
        static let hourHeight = "hourHeight"
        static let hiddenCalendars = "hiddenCalendarIDs"
        static let backgroundStyle = "backgroundStyle"
        static let backgroundOpacity = "backgroundOpacity"
        static let appearance = "appAppearance"
    }
}

private extension UserDefaults {
    func integer(forKey key: String, default fallback: Int) -> Int {
        object(forKey: key) == nil ? fallback : integer(forKey: key)
    }

    func double(forKey key: String, default fallback: Double) -> Double {
        object(forKey: key) == nil ? fallback : double(forKey: key)
    }

    func bool(forKey key: String, default fallback: Bool) -> Bool {
        object(forKey: key) == nil ? fallback : bool(forKey: key)
    }
}
