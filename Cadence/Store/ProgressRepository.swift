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
    /// Deliberately does **not** touch the task's status. It used to promote a
    /// `todo` to `doing`, which read well until you noticed that nothing ever
    /// put it back — and that Today matches `status = 'doing'`, so every task
    /// ever timed moved into Today permanently. Timing is already visible on
    /// the row, the grid and the menu bar; it does not need to smuggle itself
    /// into a smart list as well. `doing` stays what it was: something the user
    /// sets deliberately.
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

    @discardableResult
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

    /// Closes sessions that are still running for the wrong reason.
    ///
    /// Two ways a timer records time nobody worked: the Mac went to sleep with
    /// one running, and the plain forgotten one still going hours later. Both
    /// are truncated rather than left to accrue, and both say in the entry's
    /// own note why they stop where they do — a correction you can see is a
    /// correction you can undo, and every entry's times stay editable.
    ///
    /// `asleepSince` is when the machine went to sleep, if that is why we are
    /// looking. Returns the ids of the tasks whose sessions were closed.
    @discardableResult
    static func truncateAbandoned(
        _ db: Database,
        now: Date = Date(),
        asleepSince: Date? = nil,
        cap: TimeInterval = maximumUnattendedSession
    ) throws -> [String] {
        var closed: [String] = []
        for entry in try running(db) {
            let sleepCut = asleepSince.flatMap { $0 > entry.startedAt ? $0 : nil }
            let capCut = now.timeIntervalSince(entry.startedAt) > cap
                ? entry.startedAt.addingTimeInterval(cap)
                : nil

            // Whichever came first: a nap before the cap, or the cap before a
            // very long sleep.
            let cut = [sleepCut, capCut].compactMap { $0 }.min()
            guard let cut else { continue }

            let reason = cut == sleepCut
                ? "Stopped automatically — the Mac went to sleep."
                : "Stopped automatically — the timer ran past \(Int(cap / 3600))h."
            // Appended, never substituted: whatever the session already said
            // about itself is the part worth keeping.
            let note = entry.note.isEmpty ? reason : "\(entry.note)\n\(reason)"
            try stop(db, entry, at: cut, note: note)
            closed.append(entry.taskID)
        }
        return closed
    }

    /// A session running longer than this was almost certainly left on.
    static let maximumUnattendedSession: TimeInterval = 8 * 3600

    static func update(_ db: Database, _ entry: ProgressEntry) throws {
        try entry.update(db)
    }

    static func delete(_ db: Database, id: String) throws {
        try db.execute(sql: "DELETE FROM progress_entry WHERE id = ?", arguments: [id])
    }
}

// MARK: - Reporting

extension ProgressRepository {

    /// Everything recorded in a range, resolved for the report: sessions with
    /// their task and project, and the notes written alongside them.
    static func report(_ db: Database, in range: DateInterval) throws -> TimeReport {
        let entries = try ProgressEntry.fetchAll(db, sql: """
            SELECT * FROM progress_entry
            WHERE startedAt < :end AND startedAt >= :start
            ORDER BY startedAt
            """, arguments: ["start": range.start, "end": range.end])
        guard !entries.isEmpty else { return TimeReport(range: range, lines: []) }

        let todos = try TodoRepository.fetch(db, ids: Set(entries.map(\.taskID)))
        let todosByID = Dictionary(uniqueKeysWithValues: todos.map { ($0.id, $0) })
        let projects = try Project.fetchAll(db)
        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })

        let lines = entries.compactMap { entry -> TimeReport.Line? in
            guard let todo = todosByID[entry.taskID] else { return nil }
            return TimeReport.Line(
                entry: entry,
                todo: todo,
                project: todo.projectID.flatMap { projectsByID[$0] }
            )
        }
        return TimeReport(range: range, lines: lines)
    }

    /// What tasks like this one have actually taken.
    ///
    /// "Like this one" means sharing a tag, or failing that a project — the two
    /// groupings the user already maintains. Only finished tasks with recorded
    /// time count: a half-done one says nothing about how long the whole takes.
    static func calibration(
        _ db: Database,
        for todo: Todo,
        limit: Int = 40
    ) throws -> EstimateCalibration? {
        let tagIDs = try String.fetchAll(
            db,
            sql: "SELECT tagID FROM task_tag WHERE taskID = ?",
            arguments: [todo.id]
        )

        var sql = """
            SELECT t.id AS taskID,
                   t.estimateMinutes AS estimateMinutes,
                   SUM(CAST(ROUND((julianday(p.endedAt) - julianday(p.startedAt)) * 86400) AS INTEGER))
                       AS trackedSeconds
            FROM task t
            JOIN progress_entry p ON p.taskID = t.id AND p.kind = 'session' AND p.endedAt IS NOT NULL
            WHERE t.status = 'done' AND t.id <> ?
            """
        var arguments: [any DatabaseValueConvertible] = [todo.id]
        let basis: EstimateCalibration.Basis

        if !tagIDs.isEmpty {
            sql += """
                 AND EXISTS (
                   SELECT 1 FROM task_tag tt
                   WHERE tt.taskID = t.id AND tt.tagID IN (\(placeholders(tagIDs.count)))
                 )
                """
            arguments.append(contentsOf: tagIDs)
            basis = .tags
        } else if let projectID = todo.projectID {
            sql += " AND t.projectID = ?"
            arguments.append(projectID)
            basis = .project
        } else {
            return nil
        }

        sql += " GROUP BY t.id ORDER BY t.completedAt DESC LIMIT \(max(1, min(200, limit)))"

        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        let samples = rows.compactMap { row -> EstimateCalibration.Sample? in
            let seconds: Int = row["trackedSeconds"] ?? 0
            guard seconds > 0 else { return nil }
            return EstimateCalibration.Sample(
                actualMinutes: seconds / 60,
                estimateMinutes: row["estimateMinutes"]
            )
        }
        guard samples.count >= 2 else { return nil }
        return EstimateCalibration(basis: basis, samples: samples)
    }
}

/// What was recorded over a stretch of days.
struct TimeReport: Hashable {
    struct Line: Hashable, Identifiable {
        var entry: ProgressEntry
        var todo: Todo
        var project: Project?

        var id: String { entry.id }
        var minutes: Int { entry.minutes() }
    }

    var range: DateInterval
    var lines: [Line]

    var sessions: [Line] { lines.filter { $0.entry.kind == .session } }
    var notes: [Line] { lines.filter { $0.entry.kind == .note } }

    var totalMinutes: Int { sessions.reduce(0) { $0 + $1.minutes } }

    /// Totals per project, biggest first. `nil` project is "no project".
    func byProject() -> [(project: Project?, minutes: Int)] {
        var totals: [String: (Project?, Int)] = [:]
        for line in sessions {
            let key = line.project?.id ?? ""
            totals[key, default: (line.project, 0)].1 += line.minutes
        }
        return totals.values
            .map { (project: $0.0, minutes: $0.1) }
            .sorted { $0.minutes > $1.minutes }
    }

    /// Totals per task, biggest first.
    func byTask() -> [(todo: Todo, project: Project?, minutes: Int)] {
        var totals: [String: (Todo, Project?, Int)] = [:]
        for line in sessions {
            totals[line.todo.id, default: (line.todo, line.project, 0)].2 += line.minutes
        }
        return totals.values
            .map { (todo: $0.0, project: $0.1, minutes: $0.2) }
            .sorted { $0.minutes > $1.minutes }
    }

    /// Everything recorded on a given day, in the order it happened — sessions
    /// and notes together, which is what "what did I do on Tuesday" means.
    func day(_ day: Date, calendar: Calendar = .current) -> [Line] {
        lines.filter { calendar.isDate($0.entry.startedAt, inSameDayAs: day) }
    }

    var days: [Date] {
        let calendar = Calendar.current
        return Array(Set(lines.map { calendar.startOfDay(for: $0.entry.startedAt) })).sorted()
    }
}

/// How long tasks like this one have actually taken.
struct EstimateCalibration: Hashable {
    enum Basis: String, Hashable {
        case tags, project

        var title: String {
            switch self {
            case .tags: "similar tags"
            case .project: "this project"
            }
        }
    }

    struct Sample: Hashable {
        var actualMinutes: Int
        var estimateMinutes: Int?
    }

    var basis: Basis
    var samples: [Sample]

    var count: Int { samples.count }

    /// The median, not the mean: one task that swallowed a whole day should not
    /// drag the number everyone reads.
    var medianMinutes: Int {
        let sorted = samples.map(\.actualMinutes).sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    /// How the estimates on those tasks compared with what they took. `nil`
    /// when none of them were ever estimated.
    var estimateRatio: Double? {
        let estimated = samples.filter { ($0.estimateMinutes ?? 0) > 0 }
        guard !estimated.isEmpty else { return nil }
        let actual = estimated.reduce(0) { $0 + $1.actualMinutes }
        let planned = estimated.reduce(0) { $0 + ($1.estimateMinutes ?? 0) }
        guard planned > 0 else { return nil }
        return Double(actual) / Double(planned)
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
