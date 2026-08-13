import Foundation
import GRDB

/// Reads and writes for a task's timeline: time actually spent, and notes on
/// where the work got to.
///
/// Several timers may run at once — work really is interleaved, and a tool that
/// insists otherwise just loses the time it refuses to record. What is *not*
/// allowed is two sessions on the **same** task: two clocks on one thing would
/// double-count it, and there is no reading of that anyone wants.
///
/// `stoppingOthers` exists for people who would rather the app enforce one
/// thing at a time; it is a preference, off by default.
enum ProgressRepository {

    // MARK: - Reading

    /// A task's timeline, newest first — the order it is read in.
    static func entries(_ db: Database, taskID: String) throws -> [ProgressEntry] {
        try ProgressEntry.fetchAll(db, sql: """
            SELECT * FROM progress_entry WHERE taskID = ? ORDER BY startedAt DESC
            """, arguments: [taskID])
    }

    static func fetch(_ db: Database, id: String) throws -> ProgressEntry? {
        try ProgressEntry.fetchOne(db, sql: "SELECT * FROM progress_entry WHERE id = ?", arguments: [id])
    }

    /// Every session currently running, newest first.
    static func running(_ db: Database) throws -> [ProgressEntry] {
        try ProgressEntry.fetchAll(db, sql: """
            SELECT * FROM progress_entry
            WHERE kind = 'session' AND endedAt IS NULL
            ORDER BY startedAt DESC
            """)
    }

    /// The session running on one task, if any.
    static func running(_ db: Database, taskID: String) throws -> ProgressEntry? {
        try ProgressEntry.fetchOne(db, sql: """
            SELECT * FROM progress_entry
            WHERE kind = 'session' AND endedAt IS NULL AND taskID = ?
            ORDER BY startedAt DESC LIMIT 1
            """, arguments: [taskID])
    }

    /// Row summaries for a set of tasks, in one query rather than one per row.
    static func summaries(
        _ db: Database,
        taskIDs: some Collection<String>
    ) throws -> [String: ProgressSummary] {
        guard !taskIDs.isEmpty else { return [:] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT taskID,
                   -- Rounded, not truncated: julianday is a float, and the
                   -- difference across a whole hour lands a hair under 3600.
                   SUM(CASE WHEN kind = 'session' AND endedAt IS NOT NULL
                            THEN CAST(ROUND((julianday(endedAt) - julianday(startedAt)) * 86400) AS INTEGER)
                            ELSE 0 END)                                   AS trackedSeconds,
                   MAX(startedAt)                                         AS lastAt,
                   MAX(CASE WHEN kind = 'session' AND endedAt IS NULL
                            THEN startedAt ELSE NULL END)                 AS runningSince,
                   COUNT(*)                                               AS entryCount
            FROM progress_entry
            WHERE taskID IN (\(placeholders(taskIDs.count)))
            GROUP BY taskID
            """, arguments: StatementArguments(Array(taskIDs)))

        var result: [String: ProgressSummary] = [:]
        for row in rows {
            let taskID: String = row["taskID"]
            result[taskID] = ProgressSummary(
                trackedSeconds: row["trackedSeconds"] ?? 0,
                lastAt: row["lastAt"],
                runningSince: row["runningSince"],
                entryCount: row["entryCount"] ?? 0
            )
        }
        return result
    }

    /// Finished sessions overlapping `range`, plus the running one, joined with
    /// their task and project so the grid can draw them without a second pass.
    static func sessions(_ db: Database, in range: DateInterval) throws -> [TrackedSession] {
        let entries = try ProgressEntry.fetchAll(db, sql: """
            SELECT * FROM progress_entry
            WHERE kind = 'session'
              AND startedAt < :end
              AND (endedAt IS NULL OR endedAt > :start)
            ORDER BY startedAt
            """, arguments: ["start": range.start, "end": range.end])
        guard !entries.isEmpty else { return [] }

        let todos = try TodoRepository.fetch(db, ids: Set(entries.map(\.taskID)))
        let todosByID = Dictionary(uniqueKeysWithValues: todos.map { ($0.id, $0) })
        let projects = try Project.fetchAll(db)
        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })

        return entries.compactMap { entry in
            guard let todo = todosByID[entry.taskID] else { return nil }
            return TrackedSession(
                entry: entry,
                todo: todo,
                project: todo.projectID.flatMap { projectsByID[$0] }
            )
        }
    }

    // MARK: - Writing

    /// Starts timing `taskID`.
    ///
    /// Starting a task that is already being timed is a no-op rather than a
    /// second clock on the same work. With `stoppingOthers`, every other
    /// running session is closed first, in this transaction.
    ///
    /// A task that was merely "to do" becomes "doing" — you are, demonstrably,
    /// doing it.
    @discardableResult
    static func startSession(
        _ db: Database,
        taskID: String,
        at start: Date = Date(),
        stoppingOthers: Bool = false
    ) throws -> ProgressEntry {
        if let already = try running(db, taskID: taskID) { return already }
        if stoppingOthers { try stopAll(db, at: start) }

        let entry = ProgressEntry(
            taskID: taskID,
            kind: .session,
            startedAt: start,
            endedAt: nil,
            createdAt: start
        )
        try entry.insert(db)

        if var todo = try TodoRepository.fetch(db, id: taskID), todo.status == .todo {
            todo.status = .doing
            try TodoRepository.update(db, todo)
        }
        return entry
    }

    /// Stops the session running on one task. A session shorter than a minute
    /// is discarded rather than recorded — an accidental start should leave no
    /// trace.
    @discardableResult
    static func stopSession(
        _ db: Database,
        taskID: String,
        at end: Date = Date(),
        note: String = ""
    ) throws -> ProgressEntry? {
        guard let entry = try running(db, taskID: taskID) else { return nil }
        return try stop(db, entry, at: end, note: note)
    }

    /// Stops everything that is running — the end of the day, or the switch to
    /// one-at-a-time.
    @discardableResult
    static func stopAll(_ db: Database, at end: Date = Date()) throws -> [ProgressEntry] {
        try running(db).compactMap { try stop(db, $0, at: end) }
    }

    private static func stop(
        _ db: Database,
        _ entry: ProgressEntry,
        at end: Date,
        note: String = ""
    ) throws -> ProgressEntry? {
        var entry = entry
        guard end.timeIntervalSince(entry.startedAt) >= 60 else {
            try db.execute(sql: "DELETE FROM progress_entry WHERE id = ?", arguments: [entry.id])
            return nil
        }
        entry.endedAt = end
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { entry.note = trimmed }
        try entry.update(db)
        return entry
    }

    @discardableResult
    static func addNote(
        _ db: Database,
        taskID: String,
        text: String,
        at date: Date = Date()
    ) throws -> ProgressEntry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let entry = ProgressEntry(
            taskID: taskID,
            kind: .note,
            note: trimmed,
            startedAt: date,
            createdAt: date
        )
        try entry.insert(db)
        return entry
    }

    /// Records a session that has already happened — "I worked on this from 2
    /// to 4 yesterday" — without running a timer for it.
    @discardableResult
    static func addSession(
        _ db: Database,
        taskID: String,
        from start: Date,
        to end: Date,
        note: String = ""
    ) throws -> ProgressEntry {
        let entry = ProgressEntry(
            taskID: taskID,
            kind: .session,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            startedAt: start,
            endedAt: max(start, end),
            createdAt: Date()
        )
        try entry.insert(db)
        return entry
    }

    static func update(_ db: Database, _ entry: ProgressEntry) throws {
        try entry.update(db)
    }

    static func delete(_ db: Database, id: String) throws {
        try db.execute(sql: "DELETE FROM progress_entry WHERE id = ?", arguments: [id])
    }
}

/// A tracked session with the task it belongs to, for rendering on the grid.
struct TrackedSession: Identifiable, Hashable {
    var entry: ProgressEntry
    var todo: Todo
    var project: Project?

    var id: String { entry.id }
    var colorHex: String { project?.colorHex ?? Palette.unassignedBlockColor }

    func interval(now: Date = Date()) -> DateInterval? { entry.interval(now: now) }
}
