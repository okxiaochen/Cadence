import Foundation
import GRDB

extension AppModel {

    /// Everything the model needs to know about how you like to plan, snapshotted
    /// off the main actor so tool handlers on the server queue can read it.
    func planningContext() -> PlanningContext {
        let preferences = Preferences.shared
        return PlanningContext(
            workdayStartHour: preferences.workdayStartHour,
            workdayEndHour: preferences.workdayEndHour,
            includesWeekends: preferences.includesWeekends,
            defaultEstimateMinutes: preferences.defaultEstimateMinutes,
            snapMinutes: preferences.snapMinutes,
            busy: conflictIntervals(excluding: nil)
        )
    }

    /// Turns staged changes into a reviewable proposal. Validation runs against
    /// the live database, so anything that went stale during the run is caught.
    func review(
        _ changes: [ProposedChange],
        runID: String,
        summary: String,
        warnings: [String]
    ) -> Proposal {
        var proposal = Proposal(runID: runID, summary: summary, warnings: warnings)
        do {
            proposal.changes = try database.writer.read { db in
                try ProposalValidator.review(
                    changes,
                    db: db,
                    environment: ProposalValidator.Environment(
                        now: Date(),
                        busy: conflictIntervals(excluding: nil)
                    )
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        return proposal
    }

    /// Applies the accepted changes as **one** transaction and **one** undo step.
    /// Returns how many landed.
    @discardableResult
    func apply(_ proposal: Proposal, actionName: String = "AI Changes") -> Int {
        let accepted = proposal.applicableChanges.map(\.change)
        guard !accepted.isEmpty else { return 0 }

        // Blocks being moved or deleted belong to tasks we must snapshot too.
        var affected = Set(accepted.flatMap(\.affectedTaskIDs))
        let blockIDs = accepted.compactMap { change -> String? in
            switch change {
            case .moveBlock(let id, _), .deleteBlock(let id): id
            default: nil
            }
        }
        if !blockIDs.isEmpty {
            let owners = (try? database.writer.read { db in
                try blockIDs.compactMap { try TodoRepository.fetchBlock(db, id: $0)?.taskID }
            }) ?? []
            affected.formUnion(owners)
        }

        var applied = 0
        mutate(actionName, affecting: Array(affected)) { db in
            for change in accepted {
                switch change {
                case .createTask(let id, let draft):
                    let tagIDs = try draft.tagNames.map {
                        try CatalogRepository.findOrCreateTag(db, named: $0).id
                    }
                    var todo = Todo(
                        id: id,
                        title: draft.title,
                        notes: draft.notes,
                        status: .todo,
                        priority: Priority(rawValue: draft.priority) ?? .none,
                        estimateMinutes: draft.estimateMinutes,
                        projectID: draft.projectID,
                        parentID: draft.parentID,
                        dueAt: draft.dueAt
                    )
                    todo.sortOrder = try TodoRepository.nextSortOrder(db, parentID: draft.parentID)
                    try TodoRepository.insert(db, todo, tagIDs: tagIDs)

                case .updateTask(let id, let patch):
                    guard var todo = try TodoRepository.fetch(db, id: id) else { continue }
                    if let title = patch.title { todo.title = title }
                    if let notes = patch.notes { todo.notes = notes }
                    if let projectID = patch.projectID { todo.projectID = projectID }
                    if let estimate = patch.estimateMinutes { todo.estimateMinutes = estimate }
                    if let dueAt = patch.dueAt { todo.dueAt = dueAt }
                    if let deferAt = patch.deferAt { todo.deferAt = deferAt }
                    if let priority = patch.priority { todo.priority = Priority(rawValue: priority) ?? todo.priority }
                    if let raw = patch.status, let status = TodoStatus(rawValue: raw) {
                        todo.status = status
                        todo.completedAt = status.isTerminal ? Date() : nil
                    }
                    try TodoRepository.update(db, todo)

                case .createBlock(let id, let taskID, let interval):
                    try TodoRepository.insertBlock(db, TimeBlock(
                        id: id,
                        taskID: taskID,
                        startAt: interval.start,
                        endAt: interval.end,
                        source: .ai
                    ))

                case .moveBlock(let id, let interval):
                    guard var block = try TodoRepository.fetchBlock(db, id: id) else { continue }
                    block.startAt = interval.start
                    block.endAt = interval.end
                    try TodoRepository.updateBlock(db, block)

                case .deleteBlock(let id):
                    try TodoRepository.deleteBlock(db, id: id)
                }
                applied += 1
            }
        }
        return applied
    }
}

/// A thread-safe snapshot of planning preferences plus current busy time.
struct PlanningContext: @unchecked Sendable {
    var workdayStartHour: Int
    var workdayEndHour: Int
    var includesWeekends: Bool
    var defaultEstimateMinutes: Int
    var snapMinutes: Int
    var busy: [DateInterval]

    func workingHours(on day: Date, calendar: Calendar = .current) -> DateInterval? {
        let weekday = calendar.component(.weekday, from: day)
        if (weekday == 1 || weekday == 7) && !includesWeekends { return nil }
        let start = calendar.startOfDay(for: day)
        guard let from = calendar.date(byAdding: .hour, value: workdayStartHour, to: start),
              let to = calendar.date(byAdding: .hour, value: workdayEndHour, to: start),
              to > from
        else { return nil }
        return DateInterval(start: from, end: to)
    }
}
