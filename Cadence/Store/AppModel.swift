import Foundation
import GRDB
import Observation

/// The single object views read from and write through. Reads are database
/// observations (so any write, from anywhere, refreshes the UI); writes go
/// through `mutate`, which snapshots before/after and registers one undo step.
@MainActor
@Observable
final class AppModel {

    // MARK: - State

    private(set) var rows: [TodoDetail] = []
    private(set) var projects: [Project] = []
    private(set) var tags: [Tag] = []
    private(set) var smartCounts: [SmartList: Int] = [:]
    private(set) var projectCounts: [String: Int] = [:]
    private(set) var tagCounts: [String: Int] = [:]

    var query = TodoQuery() {
        didSet { if oldValue != query { restartListObservation() } }
    }

    /// Selected task ids. Multi-select drives the bulk actions in the
    /// context menu.
    var selection: Set<String> = []

    /// The task whose floating detail popover is open, if any.
    var inspectedID: String?

    var errorMessage: String?

    /// Set by the root view from the SwiftUI environment.
    var undoManager: UndoManager?

    // MARK: - Calendar state

    var calendarScale: CalendarScale = .week {
        didSet { if oldValue != calendarScale { restartCalendarObservation() } }
    }

    var calendarAnchor: Date = Date() {
        didSet {
            if !Calendar.current.isDate(oldValue, inSameDayAs: calendarAnchor) {
                restartCalendarObservation()
            }
        }
    }

    // Written only by the calendar observation in AppModel+Calendar.swift,
    // which is a different file — hence no `private(set)`.
    var scheduledBlocks: [ScheduledBlock] = []
    var unscheduled: [TodoDetail] = []
    /// Tasks due within the visible range, shown in the all-day lane.
    var dueInRange: [TodoDetail] = []

    /// Ticks once a minute. Views that show "now" read this instead of each
    /// creating their own timer.
    private(set) var clock: Date = Date()

    /// Everything scheduled from today onwards, for the menu bar. Kept separate
    /// from `scheduledBlocks`, which follows whatever week the calendar is
    /// showing — the menu bar must not change when you navigate to March.
    var agendaItems: [AgendaItem] = []
    var selectedBlockID: String?

    let eventKit = EventKitService()
    private(set) var calendarSync: CalendarSyncService!

    // MARK: - Derived

    var selectedDetails: [TodoDetail] {
        var found: [TodoDetail] = []
        for row in rows {
            if selection.contains(row.id) { found.append(row) }
            found.append(contentsOf: row.children.filter { selection.contains($0.id) })
        }
        return found
    }

    var sections: [TodoSection] { TodoGrouper.sections(rows: rows, query: query) }

    var isEmpty: Bool { rows.isEmpty }

    // MARK: - Lifecycle

    let database: AppDatabase
    private var listCancellable: AnyDatabaseCancellable?
    private var catalogCancellable: AnyDatabaseCancellable?
    var calendarCancellable: AnyDatabaseCancellable?
    var agendaCancellable: AnyDatabaseCancellable?
    private var publishTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    /// The day the agenda window was built for, so it can be rebuilt at midnight.
    var agendaAnchorDay: Date = Calendar.current.startOfDay(for: Date())

    init(database: AppDatabase) {
        self.database = database
        self.calendarSync = CalendarSyncService(store: eventKit.store, database: database)
        eventKit.managedCalendarID = calendarSync.managedCalendarID
        restartListObservation()
        startCatalogObservation()
        restartCalendarObservation()
        restartAgendaObservation()
        startClock()
    }

    private func startClock() {
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.clock = Date()
                self.refreshAgendaIfDayChanged()
            }
        }
    }

    private func restartListObservation() {
        let query = self.query
        let observation = ValueObservation.tracking { db in
            try TodoRepository.fetchDetails(db, query: query)
        }
        listCancellable = observation.start(
            in: database.writer,
            onError: { [weak self] error in
                MainActor.assumeIsolated { self?.errorMessage = error.localizedDescription }
            },
            onChange: { [weak self] rows in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.rows = rows
                    let visible = Set(rows.flatMap { [$0.id] + $0.children.map(\.id) })
                    self.selection.formIntersection(visible)
                }
            }
        )
    }

    private func startCatalogObservation() {
        let observation = ValueObservation.tracking { db in
            Catalog(
                projects: try CatalogRepository.projects(db),
                tags: try CatalogRepository.tags(db),
                smartCounts: try TodoRepository.counts(db),
                projectCounts: try CatalogRepository.openCountsByProject(db),
                tagCounts: try CatalogRepository.usageCountsByTag(db)
            )
        }
        catalogCancellable = observation.start(
            in: database.writer,
            onError: { [weak self] error in
                MainActor.assumeIsolated { self?.errorMessage = error.localizedDescription }
            },
            onChange: { [weak self] catalog in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.projects = catalog.projects
                    self.tags = catalog.tags
                    self.smartCounts = catalog.smartCounts
                    self.projectCounts = catalog.projectCounts
                    self.tagCounts = catalog.tagCounts
                }
            }
        )
    }

    private struct Catalog: Equatable {
        var projects: [Project]
        var tags: [Tag]
        var smartCounts: [SmartList: Int]
        var projectCounts: [String: Int]
        var tagCounts: [String: Int]
    }

    // MARK: - Task mutations

    @discardableResult
    func createTodo(
        title: String,
        status: TodoStatus? = nil,
        projectID: String? = nil,
        tagNames: [String] = [],
        priority: Priority = .none,
        estimateMinutes: Int? = nil,
        dueAt: Date? = nil,
        scheduledAt: Date? = nil,
        parentID: String? = nil,
        notes: String = ""
    ) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A new task inherits the context you are looking at: its project, its
        // tag, and — if the list is a day — its date.
        let contextProject = projectID ?? currentProjectID
        let contextTags = tagNames.isEmpty ? currentTagNames : tagNames
        let dueAt = dueAt ?? (scheduledAt == nil ? currentDefaultDate : nil)
        let todo = Todo(
            title: trimmed,
            notes: notes,
            status: status ?? .todo,
            priority: priority,
            estimateMinutes: estimateMinutes,
            projectID: contextProject,
            parentID: parentID,
            dueAt: dueAt
        )

        mutate("New Task", affecting: [todo.id]) { db in
            let tagIDs = try contextTags.map { try CatalogRepository.findOrCreateTag(db, named: $0).id }
            try TodoRepository.insert(db, todo, tagIDs: tagIDs)
            if let scheduledAt {
                let minutes = estimateMinutes ?? 30
                try TodoRepository.insertBlock(db, TimeBlock(
                    taskID: todo.id,
                    startAt: scheduledAt,
                    endAt: scheduledAt.addingTimeInterval(TimeInterval(minutes * 60))
                ))
            }
        }
        return todo.id
    }

    func update(_ todo: Todo, actionName: String = "Edit Task") {
        mutate(actionName, affecting: [todo.id]) { db in
            try TodoRepository.update(db, todo)
        }
    }

    func toggleCompleted(_ id: String) {
        mutate("Complete Task", affecting: [id]) { db in
            guard let todo = try TodoRepository.fetch(db, id: id) else { return }
            let next: TodoStatus = todo.isCompleted ? .todo : .done
            try TodoRepository.setStatus(db, id: id, status: next)
            // Completing a parent completes whatever is left underneath it.
            if next == .done {
                let children = try Todo.fetchAll(
                    db,
                    sql: "SELECT * FROM task WHERE parentID = ? AND status NOT IN ('done', 'cancelled')",
                    arguments: [id]
                )
                for child in children {
                    try TodoRepository.setStatus(db, id: child.id, status: .done)
                }
            }
        }
    }

    func setStatus(_ status: TodoStatus, for ids: [String]) {
        mutate(status == .done ? "Complete Task" : "Change Status", affecting: ids) { db in
            for id in ids { try TodoRepository.setStatus(db, id: id, status: status) }
        }
    }

    func delete(ids: [String]) {
        guard !ids.isEmpty else { return }
        mutate(ids.count == 1 ? "Delete Task" : "Delete Tasks", affecting: ids) { db in
            for id in ids { try TodoRepository.delete(db, id: id) }
        }
        selection.subtract(ids)
    }

    func setProject(_ projectID: String?, for ids: [String]) {
        mutate("Change Project", affecting: ids) { db in
            for id in ids {
                guard var todo = try TodoRepository.fetch(db, id: id) else { continue }
                todo.projectID = projectID
                if todo.status == .inbox && projectID != nil { todo.status = .todo }
                try TodoRepository.update(db, todo)
            }
        }
    }

    func setTags(_ tagIDs: [String], for ids: [String]) {
        mutate("Change Tags", affecting: ids) { db in
            for id in ids { try TodoRepository.setTags(db, taskID: id, tagIDs: tagIDs) }
        }
    }

    func toggleTag(_ tagID: String, for ids: [String]) {
        mutate("Change Tags", affecting: ids) { db in
            for id in ids {
                let existing = try String.fetchAll(
                    db,
                    sql: "SELECT tagID FROM task_tag WHERE taskID = ?",
                    arguments: [id]
                )
                let next = existing.contains(tagID)
                    ? existing.filter { $0 != tagID }
                    : existing + [tagID]
                try TodoRepository.setTags(db, taskID: id, tagIDs: next)
            }
        }
    }

    /// What dropping a task onto a sidebar row means.
    func applyDrop(_ selection: SidebarSelection, to ids: [String]) {
        guard !ids.isEmpty else { return }
        switch selection {
        case .smart(.today):
            moveToDay(Date(), for: ids)
        case .smart(.upcoming):
            if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) {
                moveToDay(tomorrow, for: ids)
            }
        case .smart(.anytime):
            setDueDate(nil, for: ids)
        case .smart(.logbook):
            setStatus(.done, for: ids)
        case .project(let id):
            setProject(id, for: ids)
        case .tag(let id):
            addTag(id, to: ids)
        }
    }

    /// The single date a task has. With a time it becomes a block on the grid;
    /// without one it is an all-day item; nil clears both.
    func setWhen(_ date: Date?, includesTime: Bool, for ids: [String]) {
        let fallback = Preferences.shared.defaultEstimateMinutes
        mutate(date == nil ? "Clear Date" : "Set Date", affecting: ids) { db in
            for id in ids {
                guard var todo = try TodoRepository.fetch(db, id: id) else { continue }

                guard let date else {
                    todo.dueAt = nil
                    try TodoRepository.update(db, todo)
                    try db.execute(sql: "DELETE FROM time_block WHERE taskID = ?", arguments: [id])
                    continue
                }

                if includesTime {
                    let minutes = max(5, todo.estimateMinutes ?? fallback)
                    try TodoRepository.insertBlock(db, TimeBlock(
                        taskID: id,
                        startAt: date,
                        endAt: date.addingTimeInterval(TimeInterval(minutes * 60))
                    ))
                } else {
                    try db.execute(sql: "DELETE FROM time_block WHERE taskID = ?", arguments: [id])
                    todo.dueAt = Calendar.current.startOfDay(for: date)
                    try TodoRepository.update(db, todo)
                }
            }
        }
        scheduleCalendarPublish()
    }

    /// Moves a task to another day, keeping its time of day if it had one.
    /// Dragging a 10am task from Wednesday to Friday should still be 10am.
    func moveToDay(_ day: Date, for ids: [String]) {
        let calendar = Calendar.current
        mutate("Change Date", affecting: ids) { db in
            for id in ids {
                guard let todo = try TodoRepository.fetch(db, id: id) else { continue }
                let block = try TimeBlock.fetchAll(
                    db,
                    sql: "SELECT * FROM time_block WHERE taskID = ? ORDER BY startAt",
                    arguments: [id]
                ).first

                if var block {
                    let time = calendar.dateComponents([.hour, .minute], from: block.startAt)
                    guard let start = calendar.date(
                        bySettingHour: time.hour ?? 9,
                        minute: time.minute ?? 0,
                        second: 0,
                        of: day
                    ) else { continue }
                    let duration = block.endAt.timeIntervalSince(block.startAt)
                    block.startAt = start
                    block.endAt = start.addingTimeInterval(duration)
                    try TodoRepository.updateBlock(db, block)
                } else {
                    var updated = todo
                    updated.dueAt = calendar.startOfDay(for: day)
                    try TodoRepository.update(db, updated)
                }
            }
        }
        scheduleCalendarPublish()
    }

    func setDueDate(_ date: Date?, for ids: [String]) {
        setWhen(date, includesTime: false, for: ids)
    }

    /// Drop-onto-tag adds rather than toggles: dropping the same task twice
    /// should not silently remove the tag.
    func addTag(_ tagID: String, to ids: [String]) {
        mutate("Add Tag", affecting: ids) { db in
            for id in ids {
                let existing = try String.fetchAll(
                    db,
                    sql: "SELECT tagID FROM task_tag WHERE taskID = ?",
                    arguments: [id]
                )
                guard !existing.contains(tagID) else { continue }
                try TodoRepository.setTags(db, taskID: id, tagIDs: existing + [tagID])
            }
        }
    }

    /// Estimate and block length are one value: setting one resizes the other.
    func setEstimate(_ minutes: Int?, for ids: [String]) {
        mutate("Change Estimate", affecting: ids) { db in
            for id in ids {
                try TodoRepository.setEstimate(db, taskID: id, minutes: minutes)
            }
        }
        scheduleCalendarPublish()
    }

    /// Pushes a task's block later, keeping its length. Used by the Snooze
    /// action on a notification.
    func snooze(taskID: String, byMinutes minutes: Int) {
        mutate("Snooze", affecting: [taskID]) { db in
            guard var block = try TimeBlock.fetchAll(
                db,
                sql: "SELECT * FROM time_block WHERE taskID = ? ORDER BY startAt",
                arguments: [taskID]
            ).first else { return }

            let shift = TimeInterval(minutes * 60)
            let duration = block.endAt.timeIntervalSince(block.startAt)
            let start = block.startAt.addingTimeInterval(shift)
            // Measured from the block's *current* day: using the new start
            // means a block already pushed past midnight measures against the
            // following day and the guard never fires.
            let endOfDay = Calendar.current
                .startOfDay(for: block.startAt)
                .addingTimeInterval(86_400)
            guard start.addingTimeInterval(duration) <= endOfDay else { return }

            block.startAt = start
            block.endAt = start.addingTimeInterval(duration)
            try TodoRepository.updateBlock(db, block)
        }
        scheduleCalendarPublish()
    }

    func setPriority(_ priority: Priority, for ids: [String]) {
        mutate("Change Priority", affecting: ids) { db in
            for id in ids {
                guard var todo = try TodoRepository.fetch(db, id: id) else { continue }
                todo.priority = priority
                try TodoRepository.update(db, todo)
            }
        }
    }

    @discardableResult
    func addSubtask(to parentID: String, title: String = "") -> String? {
        createTodo(title: title.isEmpty ? "New Subtask" : title, status: .todo, parentID: parentID)
    }

    /// Moves `id` to sit directly after `targetID` in manual order.
    func move(_ id: String, after targetID: String?) {
        mutate("Reorder", affecting: [id]) { db in
            guard var todo = try TodoRepository.fetch(db, id: id) else { return }
            guard let targetID, let target = try TodoRepository.fetch(db, id: targetID) else {
                todo.sortOrder = try TodoRepository.nextSortOrder(db, parentID: todo.parentID)
                try TodoRepository.update(db, todo)
                return
            }
            let nextOrder = try Double.fetchOne(db, sql: """
                SELECT MIN(sortOrder) FROM task
                WHERE sortOrder > ? AND parentID IS ? AND id <> ?
                """, arguments: [target.sortOrder, todo.parentID, id])
            todo.sortOrder = (target.sortOrder + (nextOrder ?? target.sortOrder + 2000)) / 2
            try TodoRepository.update(db, todo)
        }
    }

    // MARK: - Catalog mutations

    @discardableResult
    func createProject(name: String, colorHex: String = Palette.defaultProjectColor) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let project = Project(name: trimmed, colorHex: colorHex)
        write { db in try CatalogRepository.insert(db, project) }
        return project.id
    }

    func update(_ project: Project) {
        write { db in try CatalogRepository.update(db, project) }
    }

    func deleteProject(id: String) {
        write { db in try CatalogRepository.deleteProject(db, id: id) }
        if query.selection == .project(id) { query.selection = .smart(.today) }
    }

    @discardableResult
    func createTag(name: String) -> String? {
        var created: String?
        write { db in created = try CatalogRepository.findOrCreateTag(db, named: name).id }
        return created
    }

    func update(_ tag: Tag) {
        write { db in try CatalogRepository.update(db, tag) }
    }

    func deleteTag(id: String) {
        write { db in try CatalogRepository.deleteTag(db, id: id) }
        if query.selection == .tag(id) { query.selection = .smart(.today) }
    }

    // MARK: - Context from the current selection

    /// The project a newly-created task should land in, given what is on screen.
    var currentProjectID: String? {
        if case .project(let id) = query.selection { return id }
        return nil
    }

    /// The date a task created in the current list should get. Nil where the
    /// list says nothing about when — a project or tag is not a day.
    var currentDefaultDate: Date? {
        let calendar = Calendar.current
        switch query.selection {
        case .smart(.today):
            return calendar.startOfDay(for: Date())
        case .smart(.upcoming):
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
        case .smart(.anytime), .smart(.logbook), .project, .tag:
            return nil
        }
    }

    var currentTagNames: [String] {
        if case .tag(let id) = query.selection, let tag = tags.first(where: { $0.id == id }) {
            return [tag.name]
        }
        return []
    }

    /// The task the floating panel is showing. Falls back to the database
    /// because a calendar block's task is often not in the visible list.
    var inspectedDetail: TodoDetail? {
        guard let inspectedID else { return nil }
        if let found = detail(for: inspectedID) { return found }
        return try? database.writer.read { db in
            try TodoRepository.fetchDetail(db, id: inspectedID)
        }
    }

    func detail(for id: String) -> TodoDetail? {
        for row in rows {
            if row.id == id { return row }
            if let child = row.children.first(where: { $0.id == id }) { return child }
        }
        return nil
    }

    // MARK: - Write plumbing

    /// Coalesces publishing: a rename, a drag and an undo in quick succession
    /// should produce one reconcile, not three.
    func scheduleCalendarPublish() {
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.publishToCalendar()
        }
    }

    func write(_ work: (Database) throws -> Void) {
        do {
            try database.writer.write(work)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Runs `work` in one transaction, capturing before/after snapshots of the
    /// affected tasks so the whole thing collapses into a single undo step.
    /// Undoing re-registers the inverse, which gives redo for free.
    func mutate(
        _ actionName: String,
        affecting ids: [String],
        _ work: @escaping (Database) throws -> Void
    ) {
        do {
            let (before, after) = try database.writer.write { db -> ([TodoSnapshot], [TodoSnapshot]) in
                let before = try TodoSnapshot.capture(db, ids: ids)
                try work(db)
                // Capture the same id set afterwards, plus anything newly created
                // underneath it, so undo removes children the work added.
                let after = try TodoSnapshot.capture(db, ids: before.map(\.id))
                return (before, after)
            }
            registerUndo(actionName: actionName, restore: before, redo: after)
            scheduleCalendarPublish()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func registerUndo(actionName: String, restore: [TodoSnapshot], redo: [TodoSnapshot]) {
        guard let undoManager else { return }
        undoManager.setActionName(actionName)
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.applySnapshots(restore, actionName: actionName, inverse: redo)
            }
        }
    }

    private func applySnapshots(_ snapshots: [TodoSnapshot], actionName: String, inverse: [TodoSnapshot]) {
        do {
            try database.writer.write { db in try TodoSnapshot.restore(db, snapshots) }
            registerUndo(actionName: actionName, restore: inverse, redo: snapshots)
            scheduleCalendarPublish()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Snapshots

/// A task and everything owned by it, as it existed at a point in time.
/// `todo == nil` means "this id did not exist", so restoring deletes it.
struct TodoSnapshot {
    var id: String
    var todo: Todo?
    var tagIDs: [String]
    var blocks: [TimeBlock]

    /// Expands `ids` with every descendant, so a cascade delete or a
    /// complete-the-children edit can be undone whole.
    static func capture(_ db: Database, ids: [String]) throws -> [TodoSnapshot] {
        var expanded: [String] = []
        var seen = Set<String>()
        var frontier = ids
        while !frontier.isEmpty {
            let fresh = frontier.filter { seen.insert($0).inserted }
            expanded.append(contentsOf: fresh)
            guard !fresh.isEmpty else { break }
            frontier = try String.fetchAll(
                db,
                sql: "SELECT id FROM task WHERE parentID IN (\(placeholders(fresh.count)))",
                arguments: StatementArguments(fresh)
            )
        }

        return try expanded.map { id in
            let todo = try TodoRepository.fetch(db, id: id)
            let tagIDs = try String.fetchAll(
                db,
                sql: "SELECT tagID FROM task_tag WHERE taskID = ?",
                arguments: [id]
            )
            let blocks = try TimeBlock.fetchAll(
                db,
                sql: "SELECT * FROM time_block WHERE taskID = ?",
                arguments: [id]
            )
            return TodoSnapshot(id: id, todo: todo, tagIDs: tagIDs, blocks: blocks)
        }
    }

    static func restore(_ db: Database, _ snapshots: [TodoSnapshot]) throws {
        // Parents first, so a re-inserted child's foreign key resolves.
        let ordered = snapshots.sorted { lhs, rhs in
            (lhs.todo?.parentID == nil ? 0 : 1) < (rhs.todo?.parentID == nil ? 0 : 1)
        }
        for snapshot in ordered {
            guard let todo = snapshot.todo else {
                try TodoRepository.delete(db, id: snapshot.id)
                continue
            }
            try todo.save(db)
            try TodoRepository.setTags(db, taskID: todo.id, tagIDs: snapshot.tagIDs)
            try db.execute(sql: "DELETE FROM time_block WHERE taskID = ?", arguments: [todo.id])
            for block in snapshot.blocks { try block.insert(db) }
        }
    }
}
