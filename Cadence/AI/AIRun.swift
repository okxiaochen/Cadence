import Foundation
import GRDB

/// Where an AI run was triggered from. Each surface is a canned prompt over the
/// same agent loop (AI-INTEGRATION.md §2).
enum AISurface: String, Codable, CaseIterable {
    case chat, breakdown, generate, schedule, estimate, triage, rebalance
    /// Unattended runs: tomorrow's plan, and the weekly look back over what
    /// actually happened. Both start themselves, so they are marked as their
    /// own surfaces — a run nobody asked for should be identifiable later.
    case nightly, reflection

    /// Whether somebody asked for this just now and is there to answer.
    ///
    /// The line the whole permission model rests on. A run somebody started may
    /// ask to be allowed something new, because they are present to read the
    /// request and refuse it. A run that started itself may only use what has
    /// already been allowed — otherwise a hostile line in a feed it was told to
    /// read could ask for anything, at three in the morning, with nobody there.
    var isInteractive: Bool {
        switch self {
        case .nightly, .reflection: false
        default: true
        }
    }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .breakdown: "Break Down"
        case .generate: "Generate Todos"
        case .schedule: "Auto-schedule"
        case .estimate: "Estimate"
        case .triage: "Triage"
        case .rebalance: "Rebalance"
        case .nightly: "Nightly Plan"
        case .reflection: "Reflection"
        }
    }

    /// Appended to the system prompt to focus the run.
    var instruction: String {
        switch self {
        case .chat:
            "Answer the user's request. Only stage changes if they asked for something to change."
        case .breakdown:
            """
            Split the given task into 3–7 concrete subtasks, each with an estimate. \
            Use propose_create_task with parentID set to the task's id. Do not \
            schedule anything.
            """
        case .generate:
            """
            Turn the user's notes into discrete tasks with propose_create_task. \
            One task per actionable item. Give each a realistic estimate. Infer \
            due dates only when the text states them. Do not invent work.
            """
        case .schedule:
            """
            Place the unscheduled tasks into the calendar. Call find_free_slots \
            for each and stage the chosen slot with propose_schedule. Respect due \
            dates and never overlap busy time. If something does not fit, leave it \
            unscheduled and say so in explain.
            """
        case .estimate:
            """
            Estimate how long the task takes in minutes and stage it with \
            propose_update_task. Look at similar completed tasks for calibration.
            """
        case .triage:
            """
            For each task given, stage a project, tags, priority and estimate with \
            propose_update_task. Do not schedule anything.
            """
        case .rebalance:
            """
            Rework the schedule for the range given. Move blocks that were missed \
            into free time later in the range using propose_move_block. Drop \
            nothing without saying so in explain.
            """
        case .nightly:
            """
            Nobody is watching this run. Work only from tasks that already exist, \
            schedule less than the user's own recent records say they get through, \
            and leave the day with room in it. Never create tasks.
            """
        case .reflection:
            """
            Nobody is watching this run. Read the records, update what you know \
            about how this person works with remember, and change nothing else — \
            no tasks, no blocks. Write nothing a fortnight of records does not \
            support.
            """
        }
    }
}

struct AIRun: Identifiable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "ai_run"

    enum Status: String, Codable {
        case running, succeeded, failed, cancelled
    }

    var id: String = UUID().uuidString
    var surface: String
    var prompt: String
    var command: String
    var rawOutput: String = ""
    var status: String = Status.running.rawValue
    var startedAt: Date = Date()
    var finishedAt: Date?
    var appliedDiff: String?
    /// Which conversation this turn belongs to. Unattended runs get one each.
    var conversationID: String?

    var statusValue: Status { Status(rawValue: status) ?? .failed }
    var surfaceValue: AISurface { AISurface(rawValue: surface) ?? .chat }

    var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }
}

enum AIRunRepository {
    static func insert(_ db: Database, _ run: AIRun) throws {
        try run.insert(db)
    }

    static func update(_ db: Database, _ run: AIRun) throws {
        try run.update(db)
    }

    static func recent(_ db: Database, limit: Int = 50) throws -> [AIRun] {
        try AIRun.fetchAll(
            db,
            sql: "SELECT * FROM ai_run ORDER BY startedAt DESC LIMIT ?",
            arguments: [limit]
        )
    }

    /// Past conversations, newest first, each summarised by how it opened —
    /// which is what you actually remember a conversation by.
    static func conversations(_ db: Database, limit: Int = 40) throws -> [AIConversation] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT conversationID           AS id,
                   MIN(startedAt)           AS startedAt,
                   MAX(startedAt)           AS lastAt,
                   COUNT(*)                 AS turns,
                   MIN(surface)             AS surface
            FROM ai_run
            WHERE conversationID IS NOT NULL
            GROUP BY conversationID
            ORDER BY lastAt DESC
            LIMIT ?
            """, arguments: [limit])

        return try rows.compactMap { row in
            let id: String = row["id"]
            // The opening prompt, not the latest: it is the thing that names
            // the conversation in your head.
            let opener = try String.fetchOne(db, sql: """
                SELECT prompt FROM ai_run WHERE conversationID = ?
                ORDER BY startedAt LIMIT 1
                """, arguments: [id]) ?? ""
            return AIConversation(
                id: id,
                title: opener,
                startedAt: row["startedAt"],
                lastAt: row["lastAt"],
                turns: row["turns"] ?? 0,
                surface: AISurface(rawValue: row["surface"] ?? "") ?? .chat
            )
        }
    }

    static func runs(_ db: Database, conversationID: String) throws -> [AIRun] {
        try AIRun.fetchAll(
            db,
            sql: "SELECT * FROM ai_run WHERE conversationID = ? ORDER BY startedAt",
            arguments: [conversationID]
        )
    }

    static func deleteConversation(_ db: Database, id: String) throws {
        try db.execute(sql: "DELETE FROM ai_run WHERE conversationID = ?", arguments: [id])
    }
}

/// One thread in the assistant panel.
struct AIConversation: Identifiable, Hashable {
    var id: String
    var title: String
    var startedAt: Date
    var lastAt: Date
    var turns: Int
    var surface: AISurface

    /// Unattended runs are worth telling apart in the list: you did not start
    /// them, so their opening line will mean nothing to you.
    var displayTitle: String {
        switch surface {
        case .nightly: "Nightly plan"
        case .reflection: "Weekly reflection"
        default: title.isEmpty ? "Untitled" : title
        }
    }
}
