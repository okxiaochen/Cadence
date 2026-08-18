import Foundation
import GRDB

/// Something worth remembering between runs: a preference, a project, a goal,
/// a constraint, or something they simply care about. Deliberately *not* a
/// transcript — no task contents, no history, just the durable facts.
///
/// `interest` is the odd one and the reason the companion works at all. The
/// others exist to plan well; an interest exists so there is something to say
/// that the person would actually want to hear. Without it, everything learned
/// about somebody outside their work has nowhere to be filed and is thrown
/// away — which is how an assistant that has talked to you for a year still
/// opens with the weather.
struct Memory: Identifiable, Codable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "memory"

    enum Category: String, Codable, CaseIterable, Hashable {
        case preference, project, goal, constraint, routine, person, interest

        var title: String {
            switch self {
            case .preference: "Preference"
            case .project: "Project"
            case .goal: "Goal"
            case .constraint: "Constraint"
            case .routine: "Routine"
            case .person: "Person"
            case .interest: "Interest"
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

    /// Where this came from: `user` when they said so, `inferred` when it was
    /// drawn from their own records, or a connector name such as `meegle`.
    ///
    /// Free-form rather than an enum because every future connector would
    /// otherwise be a schema change, and the only thing the app needs to decide
    /// from it is `canGoStale`.
    var source: String = Source.user
    /// When this was last checked against reality — not merely written.
    var verifiedAt: Date?

    var categoryValue: Category { Category(rawValue: category) ?? .preference }

    enum Source {
        static let user = "user"
        static let inferred = "inferred"
    }

    /// Whether re-checking this even means anything.
    ///
    /// Something the user told us stays true until they tell us otherwise;
    /// there is no source of truth to compare it against, so "unverified for
    /// 60 days" would be noise. Everything else describes a world that moves.
    var canGoStale: Bool { source != Source.user }

    /// Days since this was last confirmed, for memories where that matters.
    func daysSinceVerified(asOf now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard canGoStale else { return nil }
        let since = verifiedAt ?? updatedAt
        return calendar.dateComponents([.day], from: since, to: now).day
    }

    func isStale(asOf now: Date = Date(), after days: Int = Memory.staleAfterDays) -> Bool {
        guard let elapsed = daysSinceVerified(asOf: now) else { return false }
        return elapsed >= days
    }

    /// A fortnight of not looking is long enough for a sprint to have turned
    /// over, and short enough that the weekly review has something to do.
    static let staleAfterDays = 14
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
    ///
    /// Writing is itself a verification: whoever wrote this just asserted it,
    /// so the clock restarts. That is what lets a stale memory be cleared by
    /// re-stating it, without a separate step.
    @discardableResult
    static func upsert(_ db: Database, _ memory: Memory, now: Date = Date()) throws -> Bool {
        let existing = try fetch(db, id: memory.id)
        var record = memory
        record.createdAt = existing?.createdAt ?? memory.createdAt
        record.updatedAt = now
        record.verifiedAt = now
        record.lastUsedAt = existing?.lastUsedAt
        try record.save(db)
        return existing != nil
    }

    /// Says "still true" without rewriting the note, so confirming something
    /// costs one call rather than a full restatement the model might garble.
    @discardableResult
    static func confirm(_ db: Database, id: String, now: Date = Date()) throws -> Bool {
        guard try fetch(db, id: id) != nil else { return false }
        try db.execute(
            sql: "UPDATE memory SET verifiedAt = ? WHERE id = ?", arguments: [now, id]
        )
        return true
    }

    /// What is worth re-checking, oldest first.
    ///
    /// Self-reported memories are excluded in SQL rather than filtered after:
    /// they are usually the bulk of the table, and there is nothing to check
    /// them against.
    static func stale(
        _ db: Database,
        asOf now: Date = Date(),
        after days: Int = Memory.staleAfterDays,
        limit: Int = 10
    ) throws -> [Memory] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        return try Memory.fetchAll(db, sql: """
            SELECT * FROM memory
            WHERE source <> ?
              AND COALESCE(verifiedAt, updatedAt) <= ?
            ORDER BY COALESCE(verifiedAt, updatedAt)
            LIMIT ?
            """, arguments: [Memory.Source.user, cutoff, limit])
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
        maxCharacters: Int = 2_000,
        now: Date = Date()
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
                // Staleness is marked inline rather than left to a tool call.
                // A model that has to ask whether a fact is current will use it
                // as though it were, and the whole point of tracking provenance
                // is that the doubt reaches the moment the fact is read.
                let warning = memory.isStale(asOf: now)
                    ? " · UNVERIFIED for \(memory.daysSinceVerified(asOf: now) ?? 0)d, "
                        + "from \(memory.source) — re-check before relying on it"
                    : ""
                lines.append("- [\(memory.id)] \(memory.categoryValue.rawValue) · "
                             + "\(memory.summary) · updated \(Format.date(memory.updatedAt))"
                             + warning)
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
