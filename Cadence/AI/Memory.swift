import Foundation
import GRDB

/// Something worth remembering between runs: a preference, a project, a goal,
/// a constraint. Deliberately *not* a transcript — no task contents, no
/// history, just the durable facts that should shape future planning.
struct Memory: Identifiable, Codable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "memory"

    enum Category: String, Codable, CaseIterable, Hashable {
        case preference, project, goal, constraint, routine, person

        var title: String {
            switch self {
            case .preference: "Preference"
            case .project: "Project"
            case .goal: "Goal"
            case .constraint: "Constraint"
            case .routine: "Routine"
            case .person: "Person"
            }
        }
    }

    /// A stable slug chosen by the model, e.g. `meeting-time-preference`.
    ///
    /// This is the mechanism that makes memory self-correcting: writing to an
    /// existing key *replaces* that memory instead of adding a contradicting
    /// second one. Without it you accumulate "dislikes morning meetings" and
    /// "likes morning meetings" side by side and neither wins.
    var id: String
    var category: String
    var title: String
    /// The one line that appears in the always-loaded outline.
    var summary: String
    /// The detail, fetched only when the model asks for it.
    var body: String = ""
    /// Pinned memories are injected in full rather than as an outline line.
    var pinned: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastUsedAt: Date?

    var categoryValue: Category { Category(rawValue: category) ?? .preference }
}

enum MemoryRepository {

    static func all(_ db: Database) throws -> [Memory] {
        try Memory.fetchAll(db, sql: """
            SELECT * FROM memory
            ORDER BY pinned DESC, COALESCE(lastUsedAt, updatedAt) DESC
            """)
    }

    static func fetch(_ db: Database, id: String) throws -> Memory? {
        try Memory.fetchOne(db, sql: "SELECT * FROM memory WHERE id = ?", arguments: [id])
    }

    static func search(_ db: Database, query: String, limit: Int = 10) throws -> [Memory] {
        let needle = "%\(query.trimmingCharacters(in: .whitespacesAndNewlines))%"
        return try Memory.fetchAll(db, sql: """
            SELECT * FROM memory
            WHERE title LIKE ? OR summary LIKE ? OR body LIKE ? OR id LIKE ?
            ORDER BY pinned DESC, COALESCE(lastUsedAt, updatedAt) DESC
            LIMIT ?
            """, arguments: [needle, needle, needle, needle, limit])
    }

    /// Insert or replace by key. Returns whether it already existed, so the
    /// model can be told it revised something rather than added it.
    @discardableResult
    static func upsert(_ db: Database, _ memory: Memory) throws -> Bool {
        let existing = try fetch(db, id: memory.id)
        var record = memory
        record.createdAt = existing?.createdAt ?? memory.createdAt
        record.updatedAt = Date()
        record.lastUsedAt = existing?.lastUsedAt
        try record.save(db)
        return existing != nil
    }

    static func delete(_ db: Database, id: String) throws -> Bool {
        guard try fetch(db, id: id) != nil else { return false }
        try db.execute(sql: "DELETE FROM memory WHERE id = ?", arguments: [id])
        return true
    }

    /// Bumps recency so the outline surfaces what actually gets used.
    static func touch(_ db: Database, id: String) throws {
        try db.execute(
            sql: "UPDATE memory SET lastUsedAt = ? WHERE id = ?",
            arguments: [Date(), id]
        )
    }

    // MARK: - Prompt rendering

    /// The always-loaded context: pinned memories in full, everything else as a
    /// single line each. Capped so a growing memory never crowds out the task.
    static func promptSection(
        _ db: Database,
        maxOutlineEntries: Int = 30,
        maxCharacters: Int = 2_000
    ) throws -> String {
        let memories = try all(db)
        guard !memories.isEmpty else { return "" }

        var lines = ["## What you know about this user"]
        let pinned = memories.filter(\.pinned)
        let rest = memories.filter { !$0.pinned }

        for memory in pinned {
            lines.append("")
            lines.append("### \(memory.title) [\(memory.id)]")
            lines.append(memory.summary)
            if !memory.body.isEmpty { lines.append(memory.body) }
        }

        if !rest.isEmpty {
            lines.append("")
            lines.append("Outline — call get_memory(\"<key>\") for the full note:")
            for memory in rest.prefix(maxOutlineEntries) {
                lines.append("- [\(memory.id)] \(memory.categoryValue.rawValue) · "
                             + "\(memory.summary) · updated \(Format.date(memory.updatedAt))")
            }
            if rest.count > maxOutlineEntries {
                lines.append("- …and \(rest.count - maxOutlineEntries) more; use search_memories.")
            }
        }

        let rendered = lines.joined(separator: "\n")
        guard rendered.count > maxCharacters else { return rendered }
        return String(rendered.prefix(maxCharacters)) + "\n…(truncated; use search_memories)"
    }
}
