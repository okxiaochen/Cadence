import Foundation
import GRDB

// The Swift type is `Todo`, not `Task`, to avoid shadowing Swift concurrency's
// `Task`. The database table is still named `task` (see SPEC.md §4).

// MARK: - Enums

enum TodoStatus: String, Codable, CaseIterable, Hashable {
    case inbox, todo, doing, done, cancelled

    var isOpen: Bool { self == .inbox || self == .todo || self == .doing }
    var isTerminal: Bool { self == .done || self == .cancelled }

    /// `inbox` is retained only so rows written before the sidebar was
    /// simplified still decode; nothing creates it and no picker offers it.
    static var selectable: [TodoStatus] { [.todo, .doing, .done, .cancelled] }

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .todo: "To Do"
        case .doing: "Doing"
        case .done: "Done"
        case .cancelled: "Cancelled"
        }
    }
}

extension TodoStatus: DatabaseValueConvertible {}

enum Priority: Int, Codable, CaseIterable, Hashable {
    case none = 0, low = 1, medium = 2, high = 3

    var title: String {
        switch self {
        case .none: "None"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    /// `nil` for `.none` so the UI can omit the badge entirely.
    var symbolName: String? {
        switch self {
        case .none: nil
        case .low: "chevron.down"
        case .medium: "equal"
        case .high: "chevron.up"
        }
    }
}

extension Priority: DatabaseValueConvertible {}

enum BlockSource: String, Codable, Hashable {
    case manual, ai
}

extension BlockSource: DatabaseValueConvertible {}

// MARK: - Records

struct Project: Identifiable, Codable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "project"

    var id: String = UUID().uuidString
    var name: String
    var colorHex: String = Palette.defaultProjectColor
    var symbolName: String? = "folder"
    var sortOrder: Double = 0
    var archivedAt: Date?

    var isArchived: Bool { archivedAt != nil }
}

struct Tag: Identifiable, Codable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "tag"

    var id: String = UUID().uuidString
    var name: String
    var colorHex: String = Palette.defaultTagColor
}

struct Todo: Identifiable, Codable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "task"

    var id: String = UUID().uuidString
    var title: String
    var notes: String = ""
    var status: TodoStatus = .todo
    var priority: Priority = .none
    var estimateMinutes: Int?
    var projectID: String?
    var parentID: String?
    var dueAt: Date?
    var deferAt: Date?
    var sortOrder: Double = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var completedAt: Date?

    var isCompleted: Bool { status == .done }
    var isSubtask: Bool { parentID != nil }

    /// True once `deferAt` has passed (or was never set).
    func isAvailable(asOf now: Date = Date()) -> Bool {
        guard status.isOpen else { return false }
        guard let deferAt else { return true }
        return deferAt <= now
    }
}

struct TimeBlock: Identifiable, Codable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "time_block"

    var id: String = UUID().uuidString
    var taskID: String
    var startAt: Date
    var endAt: Date
    var isAllDay: Bool = false
    var source: BlockSource = .manual
    var createdAt: Date = Date()
    /// The `EKEvent` we published for this block, if calendar write-back is on.
    var externalEventID: String?

    var durationMinutes: Int {
        max(0, Int((endAt.timeIntervalSince(startAt) / 60).rounded()))
    }
}

// MARK: - Join rows

struct TaskTag: Codable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "task_tag"

    var taskID: String
    var tagID: String
}

// MARK: - Composed view model row

/// A todo with everything the list and inspector need, resolved in one pass so
/// views never hit the database themselves.
struct TodoDetail: Identifiable, Hashable {
    var todo: Todo
    var project: Project?
    var tags: [Tag] = []
    var blocks: [TimeBlock] = []
    var children: [TodoDetail] = []

    var id: String { todo.id }

    var scheduledMinutes: Int { blocks.reduce(0) { $0 + $1.durationMinutes } }

    /// Minutes of estimate with no time block behind them. `nil` when there is
    /// no estimate to compare against.
    var unscheduledMinutes: Int? {
        guard let estimate = todo.estimateMinutes else { return nil }
        return max(0, estimate - scheduledMinutes)
    }

    var completedChildCount: Int { children.filter(\.todo.isCompleted).count }

    /// The date this task belongs to on a schedule: its due date, or failing
    /// that the first time it is blocked out. A task can be scheduled without
    /// ever being given a due date, and it still has a day.
    var scheduleDate: Date? {
        todo.dueAt ?? blocks.map(\.startAt).min()
    }
}

/// A time block with the task it belongs to, for rendering in the calendar.
struct ScheduledBlock: Identifiable, Hashable {
    var block: TimeBlock
    var todo: Todo
    var project: Project?

    var id: String { block.id }
    var interval: DateInterval { DateInterval(start: block.startAt, end: block.endAt) }
    var colorHex: String { project?.colorHex ?? Palette.unassignedBlockColor }
}

// MARK: - Helpers

enum Palette {
    static let defaultProjectColor = "#5E9EFF"
    static let defaultTagColor = "#8E8E93"
    /// Blocks for tasks with no project still need to be visible.
    static let unassignedBlockColor = "#5AC8FA"

    /// Colors offered when creating a project or tag.
    static let choices = [
        "#5E9EFF", "#34C759", "#FF9F0A", "#FF375F",
        "#BF5AF2", "#5AC8FA", "#FFD60A", "#8E8E93"
    ]
}
