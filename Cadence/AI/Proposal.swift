import Foundation
import GRDB

// MARK: - Drafts

struct TaskDraft: Codable, Hashable {
    var title: String
    var notes: String = ""
    var projectID: String?
    var tagNames: [String] = []
    var estimateMinutes: Int?
    var dueAt: Date?
    var priority: Int = 0
    var parentID: String?
    /// Set only when this task stands for something in another system, so
    /// accepting the proposal twice cannot produce two tasks for one work item.
    var externalID: String?
}

struct TaskPatch: Codable, Hashable {
    var title: String?
    var notes: String?
    var projectID: String??
    var estimateMinutes: Int??
    var dueAt: Date??
    var deferAt: Date??
    var priority: Int?
    var status: String?

    var isEmpty: Bool {
        title == nil && notes == nil && projectID == nil && estimateMinutes == nil
            && dueAt == nil && deferAt == nil && priority == nil && status == nil
    }
}

// MARK: - Changes

/// One staged mutation. Nothing here has touched the database yet.
enum ProposedChange: Identifiable, Hashable {
    case createTask(id: String, draft: TaskDraft)
    case updateTask(id: String, patch: TaskPatch)
    case createBlock(id: String, taskID: String, interval: DateInterval)
    case moveBlock(id: String, interval: DateInterval)
    case deleteBlock(id: String)

    var id: String {
        switch self {
        case .createTask(let id, _): "create-task-\(id)"
        case .updateTask(let id, _): "update-task-\(id)"
        case .createBlock(let id, _, _): "create-block-\(id)"
        case .moveBlock(let id, _): "move-block-\(id)"
        case .deleteBlock(let id): "delete-block-\(id)"
        }
    }

    /// Tasks whose snapshots must be captured for undo.
    var affectedTaskIDs: [String] {
        switch self {
        case .createTask(let id, _): [id]
        case .updateTask(let id, _): [id]
        case .createBlock(_, let taskID, _): [taskID]
        case .moveBlock, .deleteBlock: []   // resolved from the database at apply time
        }
    }

    var isScheduling: Bool {
        switch self {
        case .createBlock, .moveBlock, .deleteBlock: true
        case .createTask, .updateTask: false
        }
    }

    var interval: DateInterval? {
        switch self {
        case .createBlock(_, _, let interval), .moveBlock(_, let interval): interval
        default: nil
        }
    }
}

/// A change plus whether it survived validation, and a human-readable summary.
struct ReviewedChange: Identifiable, Hashable {
    var change: ProposedChange
    var summary: String
    var detail: String?
    /// Why it cannot be applied. Non-nil means it is shown struck through.
    var rejection: String?
    var isAccepted: Bool = true

    var id: String { change.id }
    var isApplicable: Bool { rejection == nil }
}

/// The reviewable result of one AI turn.
struct Proposal: Identifiable, Hashable {
    var id: String = UUID().uuidString
    var runID: String
    var summary: String = ""
    var warnings: [String] = []
    var changes: [ReviewedChange] = []

    var applicableChanges: [ReviewedChange] { changes.filter { $0.isApplicable && $0.isAccepted } }
    var rejectedChanges: [ReviewedChange] { changes.filter { !$0.isApplicable } }
    var isEmpty: Bool { changes.isEmpty }

    /// Blocks to draw as dashed ghosts on the grid.
    var ghostIntervals: [(id: String, taskTitle: String, interval: DateInterval)] {
        changes.compactMap { reviewed in
            guard reviewed.isApplicable, reviewed.isAccepted,
                  let interval = reviewed.change.interval else { return nil }
            return (reviewed.id, reviewed.summary, interval)
        }
    }

    static func == (lhs: Proposal, rhs: Proposal) -> Bool { lhs.id == rhs.id && lhs.changes == rhs.changes }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Validation

/// Checks every staged change against the real database before it is ever shown.
/// Failures are surfaced, never silently dropped — the model's mistakes should
/// be visible (AI-INTEGRATION.md §4).
enum ProposalValidator {

    struct Environment {
        var now: Date
        var busy: [DateInterval]
        var allowPast: Bool = false
        var allowOverlap: Bool = false
        var calendar: Calendar = .current
    }

    static func review(
        _ changes: [ProposedChange],
        db: Database,
        environment: Environment
    ) throws -> [ReviewedChange] {
        var reviewed: [ReviewedChange] = []
        // A batch must not contradict itself either.
        var claimed: [DateInterval] = []

        for change in changes {
            var rejection: String?
            var summary = ""
            var detail: String?

            switch change {
            case .createTask(_, let draft):
                summary = draft.title
                detail = describe(draft)
                if draft.title.trimmingCharacters(in: .whitespaces).isEmpty {
                    rejection = "Empty title"
                } else if let projectID = draft.projectID,
                          try !exists(db, table: "project", id: projectID) {
                    rejection = "Unknown project"
                } else if let parentID = draft.parentID,
                          try !exists(db, table: "task", id: parentID) {
                    rejection = "Unknown parent task"
                }

            case .updateTask(let id, let patch):
                let todo = try TodoRepository.fetch(db, id: id)
                summary = todo?.title ?? "Unknown task"
                detail = describe(patch)
                if todo == nil {
                    rejection = "Task no longer exists"
                } else if patch.isEmpty {
                    rejection = "No changes"
                } else if let status = patch.status, TodoStatus(rawValue: status) == nil {
                    rejection = "Unknown status “\(status)”"
                }

            case .createBlock(_, let taskID, let interval):
                let todo = try TodoRepository.fetch(db, id: taskID)
                summary = todo?.title ?? "Unknown task"
                detail = describe(interval)
                if let todo {
                    rejection = rejectInterval(interval, environment: environment, claimed: claimed)
                        ?? rejectTask(todo, interval: interval, environment: environment)
                } else {
                    rejection = "Task no longer exists"
                }
                if rejection == nil { claimed.append(interval) }

            case .moveBlock(let id, let interval):
                let block = try TodoRepository.fetchBlock(db, id: id)
                let todo = try block.flatMap { try TodoRepository.fetch(db, id: $0.taskID) }
                summary = todo?.title ?? "Unknown block"
                detail = describe(interval)
                if block == nil {
                    rejection = "Block no longer exists"
                } else {
                    // Its own current position is not a conflict with itself.
                    let others = environment.busy.filter { $0 != DateInterval(
                        start: block!.startAt, end: block!.endAt
                    ) }
                    var scoped = environment
                    scoped.busy = others
                    rejection = rejectInterval(interval, environment: scoped, claimed: claimed)
                }
                if rejection == nil { claimed.append(interval) }

            case .deleteBlock(let id):
                let block = try TodoRepository.fetchBlock(db, id: id)
                let todo = try block.flatMap { try TodoRepository.fetch(db, id: $0.taskID) }
                summary = todo?.title ?? "Unknown block"
                detail = block.map { describe(DateInterval(start: $0.startAt, end: $0.endAt)) }
                if block == nil { rejection = "Block no longer exists" }
            }

            reviewed.append(ReviewedChange(
                change: change,
                summary: summary,
                detail: detail,
                rejection: rejection
            ))
        }
        return reviewed
    }

    // MARK: - Rules

    private static func rejectInterval(
        _ interval: DateInterval,
        environment: Environment,
        claimed: [DateInterval]
    ) -> String? {
        if interval.duration < 300 { return "Shorter than 5 minutes" }
        if interval.duration > 12 * 3600 { return "Longer than 12 hours" }
        if !environment.calendar.isDate(
            interval.start,
            inSameDayAs: interval.end.addingTimeInterval(-1)
        ) {
            return "Spans midnight"
        }
        if !environment.allowPast && interval.start < environment.now {
            return "Starts in the past"
        }
        if !environment.allowOverlap {
            if environment.busy.contains(where: { $0.overlaps(interval) }) {
                return "Overlaps existing time"
            }
            if claimed.contains(where: { $0.overlaps(interval) }) {
                return "Overlaps another proposed block"
            }
        }
        return nil
    }

    private static func rejectTask(
        _ todo: Todo,
        interval: DateInterval,
        environment: Environment
    ) -> String? {
        if todo.status.isTerminal { return "Task is already \(todo.status.rawValue)" }
        if let deferAt = todo.deferAt, interval.start < environment.calendar.startOfDay(for: deferAt) {
            return "Before the task's defer date"
        }
        if let dueAt = todo.dueAt {
            let endOfDue = environment.calendar.startOfDay(for: dueAt).addingTimeInterval(86_400)
            if interval.end > endOfDue { return "After the task's due date" }
        }
        return nil
    }

    private static func exists(_ db: Database, table: String, id: String) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE id = ?", arguments: [id]) ?? 0 > 0
    }

    // MARK: - Descriptions

    private static func describe(_ draft: TaskDraft) -> String {
        var parts: [String] = []
        if let estimate = draft.estimateMinutes { parts.append(Format.duration(estimate)) }
        if let due = draft.dueAt { parts.append("due \(Format.date(due))") }
        if !draft.tagNames.isEmpty { parts.append(draft.tagNames.map { "#\($0)" }.joined(separator: " ")) }
        if draft.parentID != nil { parts.append("subtask") }
        return parts.joined(separator: " · ")
    }

    private static func describe(_ patch: TaskPatch) -> String {
        var parts: [String] = []
        if let title = patch.title { parts.append("title → “\(title)”") }
        if let estimate = patch.estimateMinutes { parts.append("estimate → \(estimate.map(Format.duration) ?? "none")") }
        if let due = patch.dueAt { parts.append("due → \(due.map(Format.date) ?? "none")") }
        if let status = patch.status { parts.append("status → \(status)") }
        if let priority = patch.priority { parts.append("priority → \(priority)") }
        if patch.notes != nil { parts.append("notes edited") }
        return parts.joined(separator: ", ")
    }

    private static func describe(_ interval: DateInterval) -> String {
        "\(Format.date(interval.start)) \(Format.time(interval.start))–\(Format.time(interval.end))"
    }
}
