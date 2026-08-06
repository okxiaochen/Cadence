import Foundation
import GRDB

/// All reads and writes for tasks. Pure functions over a `Database` so they can
/// be composed inside a single transaction (which is what makes one AI turn or
/// one drag a single undo step).
enum TodoRepository {

    // MARK: - Reading

    /// Resolves a `TodoQuery` into fully-populated rows: matched tasks, their
    /// parents (so a matched subtask is shown in context), children, tags and
    /// blocks — in a fixed number of queries regardless of result size.
    static func fetchDetails(
        _ db: Database,
        query: TodoQuery,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> [TodoDetail] {
        let predicate = Self.predicate(for: query, now: now, calendar: calendar)
        let matched = try Todo.fetchAll(
            db,
            sql: "SELECT * FROM task WHERE \(predicate.sql)",
            arguments: predicate.arguments
        )
        guard !matched.isEmpty else { return [] }

        var byID = Dictionary(uniqueKeysWithValues: matched.map { ($0.id, $0) })

        // Pull in parents of matched subtasks so they render nested.
        let missingParents = Set(matched.compactMap(\.parentID)).subtracting(byID.keys)
        if !missingParents.isEmpty {
            for parent in try fetch(db, ids: missingParents) { byID[parent.id] = parent }
        }

        // Pull in the children of every root we are about to show.
        let rootIDs = byID.values.filter { $0.parentID == nil }.map(\.id)
        if !rootIDs.isEmpty {
            var sql = "SELECT * FROM task WHERE parentID IN (\(placeholders(rootIDs.count)))"
            if !query.showsCompleted && !query.selection.isLogbook {
                sql += " AND status NOT IN ('done', 'cancelled')"
            }
            for child in try Todo.fetchAll(db, sql: sql, arguments: StatementArguments(rootIDs)) {
                byID[child.id] = child
            }
        }

        let ids = Array(byID.keys)
        let tagsByTask = try tagMap(db, taskIDs: ids)
        let blocksByTask = try blockMap(db, taskIDs: ids)
        let projects = try Project.fetchAll(db)
        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })

        func detail(_ todo: Todo) -> TodoDetail {
            TodoDetail(
                todo: todo,
                project: todo.projectID.flatMap { projectsByID[$0] },
                tags: tagsByTask[todo.id] ?? [],
                blocks: blocksByTask[todo.id] ?? []
            )
        }

        let childrenByParent = Dictionary(grouping: byID.values.filter { $0.parentID != nil }) {
            $0.parentID!
        }

        return byID.values
            .filter { $0.parentID == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { root in
                var row = detail(root)
                row.children = (childrenByParent[root.id] ?? [])
                    .sorted { $0.sortOrder < $1.sortOrder }
                    .map(detail)
                return row
            }
    }

    static func fetch(_ db: Database, id: String) throws -> Todo? {
        try Todo.fetchOne(db, sql: "SELECT * FROM task WHERE id = ?", arguments: [id])
    }

    static func fetch(_ db: Database, ids: some Collection<String>) throws -> [Todo] {
        guard !ids.isEmpty else { return [] }
        return try Todo.fetchAll(
            db,
            sql: "SELECT * FROM task WHERE id IN (\(placeholders(ids.count)))",
            arguments: StatementArguments(Array(ids))
        )
    }

    /// One fully-populated row, used by the inspector.
    static func fetchDetail(_ db: Database, id: String) throws -> TodoDetail? {
        guard let todo = try fetch(db, id: id) else { return nil }
        let children = try Todo.fetchAll(
            db,
            sql: "SELECT * FROM task WHERE parentID = ? ORDER BY sortOrder",
            arguments: [id]
        )
        let ids = [id] + children.map(\.id)
        let tagsByTask = try tagMap(db, taskIDs: ids)
        let blocksByTask = try blockMap(db, taskIDs: ids)
        let project = try todo.projectID.flatMap {
            try Project.fetchOne(db, sql: "SELECT * FROM project WHERE id = ?", arguments: [$0])
        }
        return TodoDetail(
            todo: todo,
            project: project,
            tags: tagsByTask[id] ?? [],
            blocks: blocksByTask[id] ?? [],
            children: children.map {
                TodoDetail(todo: $0, project: project, tags: tagsByTask[$0.id] ?? [], blocks: blocksByTask[$0.id] ?? [])
            }
        )
    }

    static func counts(_ db: Database, now: Date = Date(), calendar: Calendar = .current) throws -> [SmartList: Int] {
        var result: [SmartList: Int] = [:]
        for list in SmartList.allCases where list != .logbook {
            let query = TodoQuery(selection: .smart(list))
            let predicate = Self.predicate(for: query, now: now, calendar: calendar)
            result[list] = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM task WHERE \(predicate.sql)",
                arguments: predicate.arguments
            ) ?? 0
        }
        return result
    }

    // MARK: - Writing

    @discardableResult
    static func insert(_ db: Database, _ todo: Todo, tagIDs: [String] = []) throws -> Todo {
        var todo = todo
        if todo.sortOrder == 0 {
            todo.sortOrder = try nextSortOrder(db, parentID: todo.parentID)
        }
        try todo.insert(db)
        try setTags(db, taskID: todo.id, tagIDs: tagIDs)
        return todo
    }

    static func update(_ db: Database, _ todo: Todo) throws {
        var todo = todo
        todo.updatedAt = Date()
        try todo.update(db)
    }

    static func delete(_ db: Database, id: String) throws {
        try db.execute(sql: "DELETE FROM task WHERE id = ?", arguments: [id])
    }

    static func setStatus(_ db: Database, id: String, status: TodoStatus, now: Date = Date()) throws {
        guard var todo = try fetch(db, id: id) else { return }
        todo.status = status
        todo.completedAt = status.isTerminal ? now : nil
        try update(db, todo)
    }

    static func setTags(_ db: Database, taskID: String, tagIDs: [String]) throws {
        try db.execute(sql: "DELETE FROM task_tag WHERE taskID = ?", arguments: [taskID])
        for tagID in Set(tagIDs) {
            try TaskTag(taskID: taskID, tagID: tagID).insert(db)
        }
    }

    static func nextSortOrder(_ db: Database, parentID: String?) throws -> Double {
        let sql = parentID == nil
            ? "SELECT MAX(sortOrder) FROM task WHERE parentID IS NULL"
            : "SELECT MAX(sortOrder) FROM task WHERE parentID = ?"
        let arguments: StatementArguments = parentID == nil ? [] : [parentID]
        let max = try Double.fetchOne(db, sql: sql, arguments: arguments) ?? 0
        return max + 1000
    }

    // MARK: - Blocks

    /// Scheduling a task replaces whatever it was scheduled for before: one
    /// task, one date, one block. `dueAt` is kept identical to the block start
    /// so the two are a single concept everywhere above this layer.
    static func insertBlock(_ db: Database, _ block: TimeBlock) throws {
        try db.execute(
            sql: "DELETE FROM time_block WHERE taskID = ? AND id <> ?",
            arguments: [block.taskID, block.id]
        )
        try block.insert(db)
        try alignDate(db, taskID: block.taskID, to: block.startAt)
    }

    static func updateBlock(_ db: Database, _ block: TimeBlock) throws {
        try block.update(db)
        try alignDate(db, taskID: block.taskID, to: block.startAt)
    }

    /// Unscheduling keeps the day but drops the time, so the task becomes an
    /// all-day item rather than losing its date entirely.
    static func deleteBlock(_ db: Database, id: String) throws {
        let block = try fetchBlock(db, id: id)
        try db.execute(sql: "DELETE FROM time_block WHERE id = ?", arguments: [id])
        if let block {
            try alignDate(
                db,
                taskID: block.taskID,
                to: Calendar.current.startOfDay(for: block.startAt)
            )
        }
    }

    private static func alignDate(_ db: Database, taskID: String, to date: Date) throws {
        guard var todo = try fetch(db, id: taskID), todo.dueAt != date else { return }
        todo.dueAt = date
        try update(db, todo)
    }

    static func fetchBlock(_ db: Database, id: String) throws -> TimeBlock? {
        try TimeBlock.fetchOne(db, sql: "SELECT * FROM time_block WHERE id = ?", arguments: [id])
    }

    /// Blocks that touch `range`, joined with their task and project so the
    /// grid can render titles and colors without a second pass.
    static func scheduledBlocks(_ db: Database, in range: DateInterval) throws -> [ScheduledBlock] {
        let blocks = try TimeBlock.fetchAll(db, sql: """
            SELECT * FROM time_block
            WHERE startAt < :end AND endAt > :start
            ORDER BY startAt
            """, arguments: ["start": range.start, "end": range.end])
        guard !blocks.isEmpty else { return [] }

        let todos = try fetch(db, ids: Set(blocks.map(\.taskID)))
        let todosByID = Dictionary(uniqueKeysWithValues: todos.map { ($0.id, $0) })
        let projects = try Project.fetchAll(db)
        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })

        return blocks.compactMap { block in
            guard let todo = todosByID[block.taskID] else { return nil }
            return ScheduledBlock(
                block: block,
                todo: todo,
                project: todo.projectID.flatMap { projectsByID[$0] }
            )
        }
    }

    /// Open tasks that have a date inside `range` but no time block. Those are
    /// the all-day items; anything with a block belongs in the grid instead,
    /// and must not appear in both places.
    static func allDay(_ db: Database, in range: DateInterval) throws -> [TodoDetail] {
        let todos = try Todo.fetchAll(db, sql: """
            SELECT * FROM task
            WHERE dueAt IS NOT NULL AND dueAt >= :start AND dueAt < :end
              AND status IN ('inbox', 'todo', 'doing')
              AND NOT EXISTS (SELECT 1 FROM time_block b WHERE b.taskID = task.id)
            ORDER BY dueAt, priority DESC, sortOrder
            """, arguments: ["start": range.start, "end": range.end])
        guard !todos.isEmpty else { return [] }

        let projects = try Project.fetchAll(db)
        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let tagsByTask = try tagMap(db, taskIDs: todos.map(\.id))

        return todos.map { todo in
            TodoDetail(
                todo: todo,
                project: todo.projectID.flatMap { projectsByID[$0] },
                tags: tagsByTask[todo.id] ?? []
            )
        }
    }

    /// Open tasks with unscheduled estimate remaining — the backlog strip the
    /// calendar drags from.
    static func unscheduled(_ db: Database, limit: Int = 100) throws -> [TodoDetail] {
        let todos = try Todo.fetchAll(db, sql: """
            SELECT * FROM task
            WHERE status IN ('inbox', 'todo', 'doing')
              AND NOT EXISTS (SELECT 1 FROM time_block b WHERE b.taskID = task.id)
            ORDER BY
              CASE WHEN dueAt IS NULL THEN 1 ELSE 0 END, dueAt,
              priority DESC, sortOrder
            LIMIT ?
            """, arguments: [limit])
        guard !todos.isEmpty else { return [] }

        let ids = todos.map(\.id)
        let tagsByTask = try tagMap(db, taskIDs: ids)
        let projects = try Project.fetchAll(db)
        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })

        return todos.map { todo in
            TodoDetail(
                todo: todo,
                project: todo.projectID.flatMap { projectsByID[$0] },
                tags: tagsByTask[todo.id] ?? []
            )
        }
    }

    // MARK: - Predicate

    struct Predicate {
        var sql: String
        var arguments: StatementArguments
    }

    /// Translates a sidebar selection + search + completed toggle into SQL.
    /// Kept `internal` (not private) so tests can assert on it directly.
    static func predicate(for query: TodoQuery, now: Date, calendar: Calendar) -> Predicate {
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let horizon = calendar.date(byAdding: .day, value: TodoQuery.upcomingHorizonDays, to: startOfToday) ?? now
        let logbookCutoff = calendar.date(byAdding: .day, value: -TodoQuery.logbookHorizonDays, to: startOfToday) ?? now

        var clauses: [String] = []
        var args: [String: (any DatabaseValueConvertible)?] = [:]

        let available = "status IN ('todo', 'doing') AND (deferAt IS NULL OR deferAt <= :now)"

        switch query.selection {
        case .smart(.today):
            clauses.append("""
                \(available) AND (
                  (dueAt IS NOT NULL AND dueAt < :endOfToday)
                  OR status = 'doing'
                  OR EXISTS (
                    SELECT 1 FROM time_block b
                    WHERE b.taskID = task.id AND b.startAt >= :startOfToday AND b.startAt < :endOfToday
                  )
                )
                """)
            args["now"] = now
            args["startOfToday"] = startOfToday
            args["endOfToday"] = endOfToday

        case .smart(.upcoming):
            clauses.append("""
                \(available) AND (
                  (dueAt IS NOT NULL AND dueAt >= :endOfToday AND dueAt < :horizon)
                  OR EXISTS (
                    SELECT 1 FROM time_block b
                    WHERE b.taskID = task.id AND b.startAt >= :endOfToday AND b.startAt < :horizon
                  )
                )
                """)
            args["now"] = now
            args["endOfToday"] = endOfToday
            args["horizon"] = horizon

        case .smart(.anytime):
            // The catch-all: everything still open, deferred items included,
            // since there is no Inbox for them to hide in any more.
            clauses.append("status IN ('inbox', 'todo', 'doing')")

        case .smart(.logbook):
            clauses.append("status IN ('done', 'cancelled') AND completedAt >= :logbookCutoff")
            args["logbookCutoff"] = logbookCutoff

        case .project(let id):
            clauses.append("projectID = :projectID")
            args["projectID"] = id

        case .tag(let id):
            clauses.append("EXISTS (SELECT 1 FROM task_tag tt WHERE tt.taskID = task.id AND tt.tagID = :tagID)")
            args["tagID"] = id
        }

        // The Logbook is defined by completion, so the toggle does not apply.
        if !query.showsCompleted && !query.selection.isLogbook {
            clauses.append("status NOT IN ('done', 'cancelled')")
        }

        let search = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            clauses.append("(title LIKE :search OR notes LIKE :search)")
            args["search"] = "%\(search)%"
        }

        return Predicate(
            sql: clauses.map { "(\($0))" }.joined(separator: " AND "),
            arguments: StatementArguments(args)
        )
    }

    // MARK: - Helpers

    private static func tagMap(_ db: Database, taskIDs: some Collection<String>) throws -> [String: [Tag]] {
        guard !taskIDs.isEmpty else { return [:] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT tt.taskID AS taskID, t.*
            FROM task_tag tt
            JOIN tag t ON t.id = tt.tagID
            WHERE tt.taskID IN (\(placeholders(taskIDs.count)))
            ORDER BY t.name COLLATE NOCASE
            """, arguments: StatementArguments(Array(taskIDs)))

        var result: [String: [Tag]] = [:]
        for row in rows {
            let taskID: String = row["taskID"]
            result[taskID, default: []].append(try Tag(row: row))
        }
        return result
    }

    private static func blockMap(_ db: Database, taskIDs: some Collection<String>) throws -> [String: [TimeBlock]] {
        guard !taskIDs.isEmpty else { return [:] }
        let blocks = try TimeBlock.fetchAll(db, sql: """
            SELECT * FROM time_block WHERE taskID IN (\(placeholders(taskIDs.count))) ORDER BY startAt
            """, arguments: StatementArguments(Array(taskIDs)))
        return Dictionary(grouping: blocks, by: \.taskID)
    }
}

/// `?, ?, ?` for an `IN` clause of `count` values.
func placeholders(_ count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}

extension SidebarSelection {
    var isLogbook: Bool {
        if case .smart(.logbook) = self { return true }
        return false
    }
}
