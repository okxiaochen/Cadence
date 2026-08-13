import Foundation
import GRDB

struct MCPTool {
    var name: String
    var description: String
    var inputSchema: [String: Any]
}

enum ToolError: LocalizedError {
    case unknownTool(String)
    case missingArgument(String)
    case badArgument(String, String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name): "Unknown tool “\(name)”."
        case .missingArgument(let name): "Missing required argument “\(name)”."
        case .badArgument(let name, let why): "Argument “\(name)” is invalid: \(why)"
        }
    }
}

/// The tools exposed over MCP.
///
/// Task writes are `propose_*` and stage into a `ProposalBuffer` for review
/// (AI-INTEGRATION.md §4). Memory writes are the exception: they land straight
/// away, because memory is the assistant's own note about how to plan rather
/// than a change to the user's data.
///
/// Dispatch is deliberately separate from the HTTP layer so it can be tested
/// without a socket.
final class ToolCatalog: @unchecked Sendable {
    private let database: AppDatabase
    private let buffer: ProposalBuffer
    private let context: PlanningContext
    private let calendar: Calendar

    init(
        database: AppDatabase,
        buffer: ProposalBuffer,
        context: PlanningContext,
        calendar: Calendar = .current
    ) {
        self.database = database
        self.buffer = buffer
        self.context = context
        self.calendar = calendar
    }

    // MARK: - Descriptors

    func tools() -> [MCPTool] {
        readTools + progressTools + proposalTools + memoryTools + [
            MCPTool(
                name: "explain",
                description: "Call this LAST. Summarise what you did in one paragraph "
                    + "and list anything you could not do.",
                inputSchema: object([
                    "summary": string("One paragraph for the user"),
                    "warnings": array("Things you could not do, and why")
                ], required: ["summary"])
            )
        ]
    }

    private var readTools: [MCPTool] {
        [
            MCPTool(
                name: "list_tasks",
                description: "List tasks. Returns id, title, status, project, tags, "
                    + "estimate, due date, and how many minutes are already blocked.",
                inputSchema: object([
                    "status": string("Filter by status: todo, doing, done, cancelled"),
                    "projectID": string("Only tasks in this project"),
                    "unscheduledOnly": boolean("Only tasks with no time blocks yet"),
                    "dueBefore": string("ISO-8601 date; only tasks due before it"),
                    "limit": integer("Maximum tasks to return (default 50)")
                ])
            ),
            MCPTool(
                name: "get_task",
                description: "One task in full, including notes, subtasks and blocks.",
                inputSchema: object(["id": string("Task id")], required: ["id"])
            ),
            MCPTool(
                name: "list_projects",
                description: "All projects with their open task counts.",
                inputSchema: object([:])
            ),
            MCPTool(
                name: "list_tags",
                description: "All tags with their usage counts.",
                inputSchema: object([:])
            ),
            MCPTool(
                name: "get_schedule",
                description: "Everything already committed between two times: the "
                    + "user's task blocks, plus their calendar time as opaque busy intervals.",
                inputSchema: object([
                    "from": string("ISO-8601 start"),
                    "to": string("ISO-8601 end")
                ], required: ["from", "to"])
            ),
            MCPTool(
                name: "find_free_slots",
                description: "Ranked, concrete time slots that are actually free. "
                    + "ALWAYS use this to place work — never compute availability "
                    + "yourself. Returns slots of exactly durationMinutes, earliest first.",
                inputSchema: object([
                    "durationMinutes": integer("How long the work needs"),
                    "from": string("ISO-8601 earliest start"),
                    "to": string("ISO-8601 latest end"),
                    "withinWorkingHours": boolean("Restrict to working hours (default true)"),
                    "bufferMinutes": integer("Gap to leave around existing commitments"),
                    "count": integer("How many candidates (default 8)")
                ], required: ["durationMinutes", "from", "to"])
            ),
            MCPTool(
                name: "get_preferences",
                description: "Working hours, default estimate, snap granularity and timezone.",
                inputSchema: object([:])
            )
        ]
    }

    private var proposalTools: [MCPTool] {
        [
            MCPTool(
                name: "propose_create_task",
                description: "Stage a new task for the user to review. Does not save it.",
                inputSchema: object([
                    "title": string("Task title"),
                    "notes": string("Markdown notes"),
                    "projectID": string("Project to file it under"),
                    "tagNames": array("Tag names; created if new"),
                    "estimateMinutes": integer("How long you think it takes"),
                    "dueAt": string("ISO-8601 due date"),
                    "priority": integer("0 none, 1 low, 2 medium, 3 high"),
                    "parentID": string("Make this a subtask of that task")
                ], required: ["title"])
            ),
            MCPTool(
                name: "propose_update_task",
                description: "Stage an edit to an existing task. Only include fields "
                    + "you are changing.",
                inputSchema: object([
                    "id": string("Task id"),
                    "title": string("New title"),
                    "notes": string("New notes"),
                    "projectID": string("New project id"),
                    "estimateMinutes": integer("New estimate"),
                    "dueAt": string("ISO-8601 due date"),
                    "deferAt": string("ISO-8601 defer date"),
                    "priority": integer("0-3"),
                    "status": string("todo, doing, done or cancelled")
                ], required: ["id"])
            ),
            MCPTool(
                name: "propose_schedule",
                description: "Stage a time block for a task. Use a slot returned by "
                    + "find_free_slots; blocks that overlap busy time are rejected.",
                inputSchema: object([
                    "taskID": string("Task to schedule"),
                    "start": string("ISO-8601 start"),
                    "end": string("ISO-8601 end")
                ], required: ["taskID", "start", "end"])
            ),
            MCPTool(
                name: "propose_move_block",
                description: "Stage a move of an existing block to a new time.",
                inputSchema: object([
                    "blockID": string("Block id"),
                    "start": string("ISO-8601 start"),
                    "end": string("ISO-8601 end")
                ], required: ["blockID", "start", "end"])
            ),
            MCPTool(
                name: "propose_delete_block",
                description: "Stage the removal of a block, unscheduling that work.",
                inputSchema: object(["blockID": string("Block id")], required: ["blockID"])
            )
        ]
    }

    /// What actually happened, as against what was planned.
    ///
    /// Estimates are guesses; this is the only evidence in the database that
    /// can contradict one. Without it the assistant plans from the user's
    /// optimism and has no way to notice a task that always takes twice as
    /// long as it is given.
    private var progressTools: [MCPTool] {
        [
            MCPTool(
                name: "get_time_report",
                description: "Time actually recorded in a date range, totalled by "
                    + "project and by task, plus the progress notes written in that "
                    + "period. Use for “what did I get done last week”, and before "
                    + "planning a similar week.",
                inputSchema: object([
                    "from": string("ISO 8601 start, inclusive"),
                    "to": string("ISO 8601 end, exclusive"),
                    "includeNotes": boolean("Include the progress notes (default true)")
                ], required: ["from", "to"])
            ),
            MCPTool(
                name: "get_estimate_history",
                description: "How long finished tasks like this one actually took, from "
                    + "their tags or failing that their project. Call before estimating: "
                    + "the median here beats a guess, and the ratio says whether this "
                    + "kind of work is habitually under-estimated.",
                inputSchema: object(["id": string("Task id")], required: ["id"])
            ),
            MCPTool(
                name: "log_progress",
                description: "Add a line to a task's timeline: what got done, or what "
                    + "it is stuck on. Saved immediately — this is a journal entry, not "
                    + "an edit to the task, so it needs no review.\n\n"
                    + "Use when the user tells you what they did. Do not use it to "
                    + "restate the task, and never invent progress they did not report.",
                inputSchema: object([
                    "id": string("Task id"),
                    "note": string("One line, in the user's own terms"),
                    "at": string("ISO 8601 when it happened (default: now)")
                ], required: ["id", "note"])
            ),
            MCPTool(
                name: "log_time",
                description: "Record time already spent on a task — a session the user "
                    + "did not time. Saved immediately. Never guess the duration: only "
                    + "record what the user actually told you.",
                inputSchema: object([
                    "id": string("Task id"),
                    "from": string("ISO 8601 start"),
                    "to": string("ISO 8601 end"),
                    "note": string("What got done in it")
                ], required: ["id", "from", "to"])
            )
        ]
    }

    private var memoryTools: [MCPTool] {
        [
            MCPTool(
                name: "get_memory",
                description: "The full note behind an outline entry. The system prompt "
                    + "lists every key; call this when a line looks relevant.",
                inputSchema: object(["key": string("Memory key from the outline")], required: ["key"])
            ),
            MCPTool(
                name: "search_memories",
                description: "Find memories by keyword when the outline is truncated.",
                inputSchema: object(["query": string("Keyword to look for")], required: ["query"])
            ),
            MCPTool(
                name: "remember",
                description: "Save a durable fact about the user: a preference, project, "
                    + "goal, constraint or routine. Saved immediately.\n\n"
                    + "IMPORTANT — reuse the existing key when revising. Writing to a key "
                    + "REPLACES that memory, which is how a memory gets corrected when the "
                    + "user changes their mind. Never add a second memory that contradicts "
                    + "one already in the outline; update that one instead.\n\n"
                    + "Durable facts only. Not individual tasks, not what happened in "
                    + "this conversation.",
                inputSchema: object([
                    "key": string("Stable slug, e.g. meeting-time-preference. Reuse to revise."),
                    "category": string("preference, project, goal, constraint, routine or person"),
                    "title": string("Short name"),
                    "summary": string("One line — this is what always loads"),
                    "body": string("Detail, loaded only on request"),
                    "pinned": boolean("Load in full every time. Use sparingly.")
                ], required: ["key", "category", "title", "summary"])
            ),
            MCPTool(
                name: "forget",
                description: "Delete a memory that is no longer true and has no "
                    + "replacement. If it merely changed, call remember with the same key.",
                inputSchema: object([
                    "key": string("Memory key"),
                    "reason": string("Why it is no longer true")
                ], required: ["key"])
            )
        ]
    }

    // MARK: - Dispatch

    func call(_ name: String, arguments: [String: Any]) throws -> Any {
        switch name {
        case "list_tasks": return try listTasks(arguments)
        case "get_task": return try getTask(arguments)
        case "list_projects": return try listProjects()
        case "list_tags": return try listTags()
        case "get_schedule": return try getSchedule(arguments)
        case "find_free_slots": return try findFreeSlots(arguments)
        case "get_preferences": return preferences()
        case "propose_create_task": return try proposeCreateTask(arguments)
        case "propose_update_task": return try proposeUpdateTask(arguments)
        case "propose_schedule": return try proposeSchedule(arguments)
        case "propose_move_block": return try proposeMoveBlock(arguments)
        case "propose_delete_block": return try proposeDeleteBlock(arguments)
        case "get_time_report": return try getTimeReport(arguments)
        case "get_estimate_history": return try getEstimateHistory(arguments)
        case "log_progress": return try logProgress(arguments)
        case "log_time": return try logTime(arguments)
        case "get_memory": return try getMemory(arguments)
        case "search_memories": return try searchMemories(arguments)
        case "remember": return try remember(arguments)
        case "forget": return try forget(arguments)
        case "explain": return try explain(arguments)
        default: throw ToolError.unknownTool(name)
        }
    }

    // MARK: - Read tools

    private func listTasks(_ args: [String: Any]) throws -> Any {
        let limit = args.int("limit") ?? 50
        var clauses: [String] = []
        var bindings: [any DatabaseValueConvertible] = []

        if let status = args.string("status") {
            guard TodoStatus(rawValue: status) != nil else {
                throw ToolError.badArgument("status", "must be todo, doing, done or cancelled")
            }
            clauses.append("status = ?")
            bindings.append(status)
        } else {
            clauses.append("status IN ('inbox', 'todo', 'doing')")
        }
        if let projectID = args.string("projectID") {
            clauses.append("projectID = ?")
            bindings.append(projectID)
        }
        if args.bool("unscheduledOnly") == true {
            clauses.append("NOT EXISTS (SELECT 1 FROM time_block b WHERE b.taskID = task.id)")
        }
        if let dueBefore = try args.date("dueBefore") {
            clauses.append("dueAt IS NOT NULL AND dueAt < ?")
            bindings.append(dueBefore)
        }

        return try database.writer.read { db in
            let todos = try Todo.fetchAll(db, sql: """
                SELECT * FROM task
                WHERE \(clauses.joined(separator: " AND "))
                ORDER BY CASE WHEN dueAt IS NULL THEN 1 ELSE 0 END, dueAt, priority DESC, sortOrder
                LIMIT \(max(1, min(500, limit)))
                """, arguments: StatementArguments(bindings))
            return try todos.map { try self.encode($0, db: db) }
        }
    }

    private func getTask(_ args: [String: Any]) throws -> Any {
        guard let id = args.string("id") else { throw ToolError.missingArgument("id") }
        return try database.writer.read { db in
            guard let detail = try TodoRepository.fetchDetail(db, id: id) else {
                return ["error": "No task with id \(id)"]
            }
            var payload = try self.encode(detail.todo, db: db)
            payload["notes"] = detail.todo.notes
            payload["subtasks"] = try detail.children.map { try self.encode($0.todo, db: db) }
            payload["blocks"] = detail.blocks.map(self.encode)
            // What actually happened on it, newest first — the evidence behind
            // "this has been open for a fortnight": either nothing was done, or
            // plenty was and it is bigger than it looked.
            payload["progress"] = detail.progressEntries.map { entry in
                var line: [String: Any] = [
                    "kind": entry.kind.rawValue,
                    "at": ISO.string(entry.startedAt)
                ]
                if entry.kind == .session {
                    line["minutes"] = entry.minutes()
                    line["running"] = entry.isRunning
                }
                if !entry.note.isEmpty { line["note"] = entry.note }
                return line
            }
            return payload
        }
    }

    // MARK: - Progress tools

    private func getTimeReport(_ args: [String: Any]) throws -> Any {
        guard let from = try args.date("from") else { throw ToolError.missingArgument("from") }
        guard let to = try args.date("to") else { throw ToolError.missingArgument("to") }
        guard to > from else {
            throw ToolError.badArgument("to", "must be after from")
        }
        let includeNotes = args.bool("includeNotes") ?? true

        return try database.writer.read { db in
            let report = try ProgressRepository.report(db, in: DateInterval(start: from, end: to))
            var payload: [String: Any] = [
                "from": ISO.string(from),
                "to": ISO.string(to),
                "totalMinutes": report.totalMinutes,
                "byProject": report.byProject().map { entry in
                    [
                        "project": entry.project?.name ?? "No project",
                        "minutes": entry.minutes
                    ] as [String: Any]
                },
                "byTask": report.byTask().map { entry in
                    var line: [String: Any] = [
                        "id": entry.todo.id,
                        "title": entry.todo.title,
                        "minutes": entry.minutes
                    ]
                    if let estimate = entry.todo.estimateMinutes {
                        line["estimateMinutes"] = estimate
                    }
                    if let project = entry.project { line["project"] = project.name }
                    return line
                }
            ]
            if includeNotes {
                payload["notes"] = report.lines
                    .filter { !$0.entry.note.isEmpty }
                    .map { line in
                        [
                            "at": ISO.string(line.entry.startedAt),
                            "task": line.todo.title,
                            "note": line.entry.note
                        ] as [String: Any]
                    }
            }
            return payload
        }
    }

    private func getEstimateHistory(_ args: [String: Any]) throws -> Any {
        guard let id = args.string("id") else { throw ToolError.missingArgument("id") }
        return try database.writer.read { db in
            guard let todo = try TodoRepository.fetch(db, id: id) else {
                return ["error": "No task with id \(id)"]
            }
            guard let calibration = try ProgressRepository.calibration(db, for: todo) else {
                return [
                    "samples": 0,
                    "note": "Not enough finished, tracked tasks like this one to say anything."
                ] as [String: Any]
            }
            var payload: [String: Any] = [
                "basis": calibration.basis.rawValue,
                "samples": calibration.count,
                "medianMinutes": calibration.medianMinutes
            ]
            if let ratio = calibration.estimateRatio {
                payload["actualOverEstimate"] = (ratio * 100).rounded() / 100
            }
            return payload
        }
    }

    private func logProgress(_ args: [String: Any]) throws -> Any {
        guard let id = args.string("id") else { throw ToolError.missingArgument("id") }
        guard let note = args.string("note"), !note.trimmingCharacters(in: .whitespaces).isEmpty
        else { throw ToolError.missingArgument("note") }
        let at = try args.date("at") ?? Date()

        return try database.writer.write { db in
            guard try TodoRepository.fetch(db, id: id) != nil else {
                return ["error": "No task with id \(id)"]
            }
            let entry = try ProgressRepository.addNote(db, taskID: id, text: note, at: at)
            return ["logged": entry != nil, "at": ISO.string(at)] as [String: Any]
        }
    }

    private func logTime(_ args: [String: Any]) throws -> Any {
        guard let id = args.string("id") else { throw ToolError.missingArgument("id") }
        guard let from = try args.date("from") else { throw ToolError.missingArgument("from") }
        guard let to = try args.date("to") else { throw ToolError.missingArgument("to") }
        guard to > from else { throw ToolError.badArgument("to", "must be after from") }

        return try database.writer.write { db in
            guard try TodoRepository.fetch(db, id: id) != nil else {
                return ["error": "No task with id \(id)"]
            }
            let entry = try ProgressRepository.addSession(
                db,
                taskID: id,
                from: from,
                to: to,
                note: args.string("note") ?? ""
            )
            return ["logged": true, "minutes": entry.minutes()] as [String: Any]
        }
    }

    private func listProjects() throws -> Any {
        try database.writer.read { db in
            let counts = try CatalogRepository.openCountsByProject(db)
            return try CatalogRepository.projects(db).map { project in
                [
                    "id": project.id,
                    "name": project.name,
                    "openTasks": counts[project.id] ?? 0
                ] as [String: Any]
            }
        }
    }

    private func listTags() throws -> Any {
        try database.writer.read { db in
            let counts = try CatalogRepository.usageCountsByTag(db)
            return try CatalogRepository.tags(db).map { tag in
                ["id": tag.id, "name": tag.name, "openTasks": counts[tag.id] ?? 0] as [String: Any]
            }
        }
    }

    private func getSchedule(_ args: [String: Any]) throws -> Any {
        guard let from = try args.date("from") else { throw ToolError.missingArgument("from") }
        guard let to = try args.date("to") else { throw ToolError.missingArgument("to") }
        guard to > from else { throw ToolError.badArgument("to", "must be after from") }

        let range = DateInterval(start: from, end: to)
        let blocks = try database.writer.read { db in
            try TodoRepository.scheduledBlocks(db, in: range)
        }
        // Calendar events arrive as opaque busy intervals: the model is told
        // when the user is busy, never what they are doing.
        let events = context.busy
            .filter { $0.overlaps(range) }
            .map { ["start": ISO.string($0.start), "end": ISO.string($0.end)] }

        return [
            "blocks": blocks.map { block in
                [
                    "blockID": block.block.id,
                    "taskID": block.todo.id,
                    "title": block.todo.title,
                    "start": ISO.string(block.block.startAt),
                    "end": ISO.string(block.block.endAt),
                    "minutes": block.block.durationMinutes
                ] as [String: Any]
            },
            "busy": events
        ]
    }

    private func findFreeSlots(_ args: [String: Any]) throws -> Any {
        guard let minutes = args.int("durationMinutes") else {
            throw ToolError.missingArgument("durationMinutes")
        }
        guard let from = try args.date("from") else { throw ToolError.missingArgument("from") }
        guard let to = try args.date("to") else { throw ToolError.missingArgument("to") }
        guard to > from else { throw ToolError.badArgument("to", "must be after from") }

        let constraints = SlotConstraints(
            durationMinutes: minutes,
            range: DateInterval(start: from, end: to),
            withinWorkingHours: args.bool("withinWorkingHours") ?? true,
            bufferMinutes: args.int("bufferMinutes") ?? 0,
            granularityMinutes: context.snapMinutes,
            limit: args.int("count") ?? 8
        )
        let slots = SlotFinder.find(
            constraints: constraints,
            busy: context.busy,
            workingHours: { context.workingHours(on: $0, calendar: calendar) },
            calendar: calendar
        )
        if slots.isEmpty {
            return [
                "slots": [],
                "note": "Nothing of that length is free in that range. Try a shorter "
                    + "duration, a wider range, or withinWorkingHours=false."
            ] as [String: Any]
        }
        return ["slots": slots.map { slot in
            [
                "start": ISO.string(slot.start),
                "end": ISO.string(slot.end),
                "reasons": slot.reasons
            ] as [String: Any]
        }]
    }

    private func preferences() -> Any {
        [
            "timezone": calendar.timeZone.identifier,
            "today": ISO.string(Date()),
            "workdayStartHour": context.workdayStartHour,
            "workdayEndHour": context.workdayEndHour,
            "includesWeekends": context.includesWeekends,
            "defaultEstimateMinutes": context.defaultEstimateMinutes,
            "snapMinutes": context.snapMinutes
        ]
    }

    // MARK: - Proposal tools (staged only)

    private func proposeCreateTask(_ args: [String: Any]) throws -> Any {
        guard let title = args.string("title") else { throw ToolError.missingArgument("title") }
        let id = UUID().uuidString
        buffer.stage(.createTask(id: id, draft: TaskDraft(
            title: title,
            notes: args.string("notes") ?? "",
            projectID: args.string("projectID"),
            tagNames: args.strings("tagNames"),
            estimateMinutes: args.int("estimateMinutes"),
            dueAt: try args.date("dueAt"),
            priority: args.int("priority") ?? 0,
            parentID: args.string("parentID")
        )))
        return ["staged": true, "taskID": id,
                "note": "Not saved yet — the user reviews this before it is applied."]
    }

    private func proposeUpdateTask(_ args: [String: Any]) throws -> Any {
        guard let id = args.string("id") else { throw ToolError.missingArgument("id") }
        var patch = TaskPatch()
        patch.title = args.string("title")
        patch.notes = args.string("notes")
        if args["projectID"] != nil { patch.projectID = .some(args.string("projectID")) }
        if args["estimateMinutes"] != nil { patch.estimateMinutes = .some(args.int("estimateMinutes")) }
        if args["dueAt"] != nil { patch.dueAt = .some(try args.date("dueAt")) }
        if args["deferAt"] != nil { patch.deferAt = .some(try args.date("deferAt")) }
        patch.priority = args.int("priority")
        patch.status = args.string("status")

        buffer.stage(.updateTask(id: id, patch: patch))
        return ["staged": true]
    }

    private func proposeSchedule(_ args: [String: Any]) throws -> Any {
        guard let taskID = args.string("taskID") else { throw ToolError.missingArgument("taskID") }
        let interval = try requireInterval(args, startKey: "start", endKey: "end")
        buffer.stage(.createBlock(id: UUID().uuidString, taskID: taskID, interval: interval))
        return ["staged": true]
    }

    private func proposeMoveBlock(_ args: [String: Any]) throws -> Any {
        guard let blockID = args.string("blockID") else { throw ToolError.missingArgument("blockID") }
        let interval = try requireInterval(args, startKey: "start", endKey: "end")
        buffer.stage(.moveBlock(id: blockID, interval: interval))
        return ["staged": true]
    }

    private func proposeDeleteBlock(_ args: [String: Any]) throws -> Any {
        guard let blockID = args.string("blockID") else { throw ToolError.missingArgument("blockID") }
        buffer.stage(.deleteBlock(id: blockID))
        return ["staged": true]
    }

    // MARK: - Memory
    //
    // These write straight through rather than staging. Memory is the app's own
    // note about how to plan, not a change to the user's tasks, and putting it
    // behind review would mean the assistant never learns anything.

    private func getMemory(_ args: [String: Any]) throws -> Any {
        guard let key = args.string("key") else { throw ToolError.missingArgument("key") }
        return try database.writer.write { db -> [String: Any] in
            guard let memory = try MemoryRepository.fetch(db, id: Self.slug(key)) else {
                return ["error": "No memory with key \(key)"]
            }
            // Recency drives which memories stay in the outline.
            try MemoryRepository.touch(db, id: memory.id)
            return [
                "key": memory.id,
                "category": memory.category,
                "title": memory.title,
                "summary": memory.summary,
                "body": memory.body,
                "updatedAt": ISO.string(memory.updatedAt)
            ]
        }
    }

    private func searchMemories(_ args: [String: Any]) throws -> Any {
        guard let query = args.string("query") else { throw ToolError.missingArgument("query") }
        return try database.writer.read { db in
            try MemoryRepository.search(db, query: query).map { memory in
                [
                    "key": memory.id,
                    "category": memory.category,
                    "summary": memory.summary,
                    "updatedAt": ISO.string(memory.updatedAt)
                ] as [String: Any]
            }
        }
    }

    private func remember(_ args: [String: Any]) throws -> Any {
        guard let key = args.string("key") else { throw ToolError.missingArgument("key") }
        guard let title = args.string("title") else { throw ToolError.missingArgument("title") }
        guard let summary = args.string("summary") else { throw ToolError.missingArgument("summary") }
        guard let rawCategory = args.string("category"),
              let category = Memory.Category(rawValue: rawCategory.lowercased())
        else {
            throw ToolError.badArgument(
                "category",
                "must be one of " + Memory.Category.allCases.map(\.rawValue).joined(separator: ", ")
            )
        }

        let slug = Self.slug(key)
        guard !slug.isEmpty else {
            throw ToolError.badArgument("key", "must contain letters or digits")
        }

        let memory = Memory(
            id: slug,
            category: category.rawValue,
            title: title,
            summary: summary,
            body: args.string("body") ?? "",
            pinned: args.bool("pinned") ?? false
        )
        let revised = try database.writer.write { db in
            try MemoryRepository.upsert(db, memory)
        }
        return [
            "saved": true,
            "key": slug,
            "revised": revised,
            "note": revised
                ? "Replaced the previous version of this memory."
                : "Stored a new memory."
        ]
    }

    private func forget(_ args: [String: Any]) throws -> Any {
        guard let key = args.string("key") else { throw ToolError.missingArgument("key") }
        let removed = try database.writer.write { db in
            try MemoryRepository.delete(db, id: Self.slug(key))
        }
        return ["forgotten": removed]
    }

    /// Keys come from a model, so they are normalised before they become
    /// identities — otherwise `Meeting Times` and `meeting-times` diverge and
    /// the self-correcting overwrite silently stops working.
    static func slug(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func explain(_ args: [String: Any]) throws -> Any {
        guard let summary = args.string("summary") else { throw ToolError.missingArgument("summary") }
        buffer.explain(summary: summary, warnings: args.strings("warnings"))
        return ["recorded": true, "stagedChanges": buffer.count]
    }

    // MARK: - Encoding

    private func encode(_ todo: Todo, db: Database) throws -> [String: Any] {
        // ROUND before CAST: julianday is floating point, so a 60-minute block
        // comes out as 59.999… and a bare CAST truncates it to 59.
        let scheduled = try Int.fetchOne(db, sql: """
            SELECT COALESCE(SUM(CAST(ROUND((julianday(endAt) - julianday(startAt)) * 1440) AS INTEGER)), 0)
            FROM time_block WHERE taskID = ?
            """, arguments: [todo.id]) ?? 0
        let tags = try String.fetchAll(db, sql: """
            SELECT t.name FROM task_tag tt JOIN tag t ON t.id = tt.tagID WHERE tt.taskID = ?
            """, arguments: [todo.id])
        // Time actually spent, beside the estimate it should be judged against.
        let tracked = try ProgressRepository.summaries(db, taskIDs: [todo.id])[todo.id]?
            .trackedMinutes() ?? 0

        var payload: [String: Any] = [
            "id": todo.id,
            "title": todo.title,
            "status": todo.status.rawValue,
            "priority": todo.priority.rawValue,
            "tags": tags,
            "scheduledMinutes": scheduled,
            "trackedMinutes": tracked
        ]
        if let projectID = todo.projectID { payload["projectID"] = projectID }
        if let estimate = todo.estimateMinutes { payload["estimateMinutes"] = estimate }
        if let dueAt = todo.dueAt { payload["dueAt"] = ISO.string(dueAt) }
        if let deferAt = todo.deferAt { payload["deferAt"] = ISO.string(deferAt) }
        if let parentID = todo.parentID { payload["parentID"] = parentID }
        return payload
    }

    private func encode(_ block: TimeBlock) -> [String: Any] {
        [
            "blockID": block.id,
            "start": ISO.string(block.startAt),
            "end": ISO.string(block.endAt),
            "minutes": block.durationMinutes
        ]
    }

    private func requireInterval(
        _ args: [String: Any],
        startKey: String,
        endKey: String
    ) throws -> DateInterval {
        guard let start = try args.date(startKey) else { throw ToolError.missingArgument(startKey) }
        guard let end = try args.date(endKey) else { throw ToolError.missingArgument(endKey) }
        guard end > start else { throw ToolError.badArgument(endKey, "must be after \(startKey)") }
        return DateInterval(start: start, end: end)
    }

    // MARK: - Schema helpers

    private func object(_ properties: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    private func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private func integer(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description]
    }

    private func boolean(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    private func array(_ description: String) -> [String: Any] {
        ["type": "array", "items": ["type": "string"], "description": description]
    }
}

// MARK: - Argument reading

enum ISO {
    static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let dateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    static func string(_ date: Date) -> String { formatter.string(from: date) }

    /// Accepts full ISO-8601, fractional seconds, or a bare `yyyy-MM-dd`, which
    /// models produce constantly.
    static func date(_ text: String) -> Date? {
        formatter.date(from: text)
            ?? withFractional.date(from: text)
            ?? dateOnly.date(from: text)
    }
}

extension [String: Any] {
    func string(_ key: String) -> String? {
        guard let value = self[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    func int(_ key: String) -> Int? {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? Double { return Int(value) }
        if let value = self[key] as? String { return Int(value) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let value = self[key] as? Bool { return value }
        if let value = self[key] as? String { return value == "true" }
        return nil
    }

    func strings(_ key: String) -> [String] {
        if let values = self[key] as? [String] { return values }
        if let single = self[key] as? String { return [single] }
        return []
    }

    func date(_ key: String) throws -> Date? {
        guard let text = self.string(key) else { return nil }
        guard let date = ISO.date(text) else {
            throw ToolError.badArgument(key, "expected an ISO-8601 date, got “\(text)”")
        }
        return date
    }
}
