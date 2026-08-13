import Foundation

// MARK: - Sidebar selection

enum SmartList: String, CaseIterable, Identifiable, Hashable {
    case today, upcoming, anytime, stalled, logbook

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .upcoming: "Upcoming"
        case .anytime: "Anytime"
        case .stalled: "Stalled"
        case .logbook: "Logbook"
        }
    }

    var symbolName: String {
        switch self {
        case .today: "star"
        case .upcoming: "calendar"
        case .anytime: "tray.full"
        case .stalled: "hourglass"
        case .logbook: "checkmark.circle"
        }
    }
}

/// How long a task can sit with nothing happening before it counts as stalled.
///
/// Undated work does not fall out of any other list — Anytime holds everything
/// open, so the one thing you have been quietly avoiding looks exactly like the
/// forty things you simply have not got to yet. This is the list that asks the
/// question nobody volunteers to answer.
enum StalledList {
    static let quietDays = 14
}

enum SidebarSelection: Hashable {
    case smart(SmartList)
    case project(String)
    case tag(String)

    /// Stable key for remembering how this list is grouped and sorted.
    var storageKey: String {
        switch self {
        case .smart(let list): "smart.\(list.rawValue)"
        case .project(let id): "project.\(id)"
        case .tag(let id): "tag.\(id)"
        }
    }
}

// MARK: - Grouping & sorting

enum TodoGrouping: String, CaseIterable, Identifiable, Hashable {
    case none, day, project, tag, dueDate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "No Grouping"
        case .day: "Day"
        case .project: "Project"
        case .tag: "Tag"
        case .dueDate: "Due Date"
        }
    }
}

enum TodoSort: String, CaseIterable, Identifiable, Hashable {
    case manual, dueDate, priority, created

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "Manual"
        case .dueDate: "Due Date"
        case .priority: "Priority"
        case .created: "Date Added"
        }
    }
}

// MARK: - Query

/// Everything needed to turn a sidebar selection into a SQL query. Held by
/// `TodoListModel`; a change restarts the underlying database observation.
struct TodoQuery: Hashable {
    var selection: SidebarSelection = .smart(.today)
    var grouping: TodoGrouping = .none
    var sort: TodoSort = .manual
    var searchText: String = ""
    var showsCompleted: Bool = false

    /// Upcoming is a schedule, so it reads best broken down by day — the same
    /// shape Apple Reminders uses. Picking any grouping explicitly overrides it.
    var resolvedGrouping: TodoGrouping {
        if grouping == .none, case .smart(.upcoming) = selection { return .day }
        return grouping
    }

    /// How far ahead `.upcoming` looks.
    static let upcomingHorizonDays = 14

    /// Completed items older than this drop out of the Logbook.
    static let logbookHorizonDays = 30
}

// MARK: - Section

struct TodoSection: Identifiable, Hashable {
    var id: String
    var title: String
    var symbolName: String?
    var colorHex: String?
    var items: [TodoDetail]
    /// Chronological order for day sections; unused by the other groupings.
    var sortKey: Double = 0
    /// The day this section stands for, so adding a task inside it can set the
    /// date without the user typing one.
    var date: Date?
    /// Empty day sections are still shown, so there is somewhere to add to.
    var acceptsQuickAdd: Bool = false
}
