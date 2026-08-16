import AppKit
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
        allowsConcurrentTimers = defaults.bool(forKey: Key.concurrentTimers, default: true)
        snapMinutes = defaults.integer(forKey: Key.snapMinutes, default: 15)
        storedHourHeight = min(200, max(24, defaults.double(forKey: Key.hourHeight, default: 48)))
        hiddenCalendarIDs = Set(defaults.stringArray(forKey: Key.hiddenCalendars) ?? [])
        showsOverdue = defaults.bool(forKey: Key.showsOverdue, default: true)
        meegleEnabled = defaults.bool(forKey: Key.meegle, default: false)
        showsDesktopPet = defaults.bool(forKey: Key.pet, default: false)
        breakAfterMinutes = defaults.integer(forKey: Key.breakAfter, default: 50)
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

    /// Whether several tasks may be timed at once. On by default: work really
    /// does interleave, and a timer that stops your other timer silently loses
    /// the time it refused to record. Switch it off to have starting one task
    /// stop the rest.
    var allowsConcurrentTimers: Bool {
        didSet { defaults.set(allowsConcurrentTimers, forKey: Key.concurrentTimers) }
    }

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

    // MARK: - Desktop companion

    /// Off by default. A window that sits on the desktop whatever else you are
    /// doing is a decision somebody makes, not one they discover.
    var showsDesktopPet: Bool { didSet { defaults.set(showsDesktopPet, forKey: Key.pet) } }

    /// Minutes at the clock before it suggests stopping.
    var breakAfterMinutes: Int {
        didSet { defaults.set(breakAfterMinutes, forKey: Key.breakAfter) }
    }

    /// Where it was last dragged to, so it stays where it was put.
    var petWindowOrigin: NSPoint? {
        get {
            guard let stored = defaults.array(forKey: Key.petOrigin) as? [Double],
                  stored.count == 2 else { return nil }
            return NSPoint(x: stored[0], y: stored[1])
        }
        set {
            guard let newValue else { return defaults.removeObject(forKey: Key.petOrigin) }
            defaults.set([newValue.x, newValue.y], forKey: Key.petOrigin)
        }
    }

    // MARK: - Connectors

    /// Whether the AI may read the user's Meegle (Lark Project) work items.
    ///
    /// Off by default. It reaches outside the app to a work account, which is a
    /// decision the user makes deliberately rather than discovers — the same
    /// reasoning as `ExternalAgentService`. While it is off the tools are not
    /// merely refused, they are absent from the catalog.
    var meegleEnabled: Bool { didSet { defaults.set(meegleEnabled, forKey: Key.meegle) } }

    // MARK: - Menu bar

    /// Whether overdue work is listed in the menu bar agenda, and counted by
    /// the status item.
    ///
    /// One flag for both on purpose: collapsing the section means "not now",
    /// and a badge that goes on reporting a number you have just put away is
    /// the nagging the collapse was for.
    var showsOverdue: Bool { didSet { defaults.set(showsOverdue, forKey: Key.showsOverdue) } }

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

    // MARK: - Per-list view options

    /// How each list is grouped and sorted, remembered per list.
    ///
    /// Global would be wrong: "group Anytime by project" and "leave Today as a
    /// flat list" are both reasonable at the same time, and having to re-pick
    /// on every switch is why the menu felt like it did nothing.
    func viewOptions(for selection: SidebarSelection) -> (grouping: TodoGrouping, sort: TodoSort)? {
        guard let stored = defaults.dictionary(forKey: Key.viewOptions)?[selection.storageKey]
                as? [String: String] else { return nil }
        guard let grouping = stored["grouping"].flatMap(TodoGrouping.init(rawValue:)),
              let sort = stored["sort"].flatMap(TodoSort.init(rawValue:))
        else { return nil }
        return (grouping, sort)
    }

    func setViewOptions(
        grouping: TodoGrouping,
        sort: TodoSort,
        for selection: SidebarSelection
    ) {
        var all = defaults.dictionary(forKey: Key.viewOptions) as? [String: [String: String]] ?? [:]
        all[selection.storageKey] = ["grouping": grouping.rawValue, "sort": sort.rawValue]
        defaults.set(all, forKey: Key.viewOptions)
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
        static let concurrentTimers = "allowsConcurrentTimers"
        static let snapMinutes = "snapMinutes"
        static let hourHeight = "hourHeight"
        static let hiddenCalendars = "hiddenCalendarIDs"
        // The key the menu bar's own `@AppStorage` used, so anyone who has
        // already collapsed the section keeps it collapsed.
        static let showsOverdue = "menuBarShowsOverdue"
        static let meegle = "meegleEnabled"
        static let pet = "showsDesktopPet"
        static let breakAfter = "breakAfterMinutes"
        static let petOrigin = "petWindowOrigin"
        static let backgroundStyle = "backgroundStyle"
        static let backgroundOpacity = "backgroundOpacity"
        static let appearance = "appAppearance"
        static let viewOptions = "listViewOptions"
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
