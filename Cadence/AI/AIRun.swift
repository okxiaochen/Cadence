import Foundation
import GRDB

/// Where an AI run was triggered from. Each surface is a canned prompt over the
/// same agent loop (AI-INTEGRATION.md §2).
enum AISurface: String, Codable, CaseIterable {
    case chat, breakdown, generate, schedule, estimate, triage, rebalance

    var title: String {
        switch self {
        case .chat: "Chat"
        case .breakdown: "Break Down"
        case .generate: "Generate Todos"
        case .schedule: "Auto-schedule"
        case .estimate: "Estimate"
        case .triage: "Triage"
        case .rebalance: "Rebalance"
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
}
