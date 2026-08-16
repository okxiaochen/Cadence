import Foundation
import GRDB

/// A procedure the assistant can follow, as against a fact it knows.
///
/// `Memory` holds what is true about this person — "does not like morning
/// meetings". A skill holds how a thing is done — "to bring a ticket across:
/// check whether it is already here, reword the title as an action, keep the
/// original wording in the notes". The split matters because they are used
/// differently: a fact is applied, a procedure is followed, and a procedure is
/// far too long to sit in every prompt.
///
/// Hence `whenToUse`, which is the only part always loaded. A memory's summary
/// answers *what is true*; a skill's has to answer *when should I reach for
/// this*, because the model decides from that one line whether to spend a call
/// fetching the rest.
struct Skill: Identifiable, Codable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "skill"

    /// A stable slug, e.g. `meegle-work-items`. Writing to an existing key
    /// replaces that skill, exactly as memory does.
    var id: String
    var title: String
    /// The one line that appears in the always-loaded outline.
    var whenToUse: String
    /// The steps. Fetched only when the model asks.
    var body: String = ""
    /// `built-in` for anything shipped with the app, otherwise the same
    /// vocabulary memories use: `user`, `inferred`, or a connector's name.
    var source: String = Source.user
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var verifiedAt: Date?
    var lastUsedAt: Date?
    /// Set only on a row that overrides a built-in, to the built-in set version
    /// it was written against.
    ///
    /// Without it an edited copy silently forks: the shipped version improves,
    /// the user's override keeps winning — correctly, it was deliberate — and
    /// nothing ever tells them they are on an old branch of it.
    var basedOnBuiltInVersion: Int?

    enum Source {
        static let builtIn = "built-in"
        static let user = "user"
        static let inferred = "inferred"
    }

    var isBuiltIn: Bool { source == Source.builtIn }

    /// A built-in cannot go stale from here — it is replaced by updating the
    /// app, not by re-checking it. Everything else follows the same rule
    /// memories do.
    var canGoStale: Bool { source != Source.builtIn && source != Source.user }

    /// Days since anyone confirmed these steps, for the procedures where that
    /// means anything. Nil for a built-in or something the user dictated —
    /// there is nothing to have checked them against.
    func daysSinceVerified(asOf now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard canGoStale else { return nil }
        return calendar.dateComponents([.day], from: verifiedAt ?? updatedAt, to: now).day
    }

    func isStale(asOf now: Date = Date(), after days: Int = Memory.staleAfterDays) -> Bool {
        guard let elapsed = daysSinceVerified(asOf: now) else { return false }
        return elapsed >= days
    }
}

// MARK: - The set that ships with the app

/// A versioned collection of built-in skills.
///
/// The version is a sequence of its own, deliberately unrelated to the app's:
/// its only job is to decide which provider of the built-in set wins. Today
/// there is one provider, the copy in the bundle. If a downloadable pack is
/// ever added it is the same format and the same parser, and the higher version
/// simply wins — which is why the number is here from the start rather than
/// retrofitted onto a shape that had no room for it.
///
/// **Anything downloaded must be signed** with the key in `ReleaseSignature`
/// before it is parsed. A skill is a set of instructions an assistant holding
/// write tools will follow; an unsigned one is an instruction channel into the
/// user's data.
struct SkillPack: Decodable, Equatable {
    var version: Int
    var skills: [Entry]

    struct Entry: Decodable, Equatable {
        var id: String
        var title: String
        var whenToUse: String
        var body: String
    }

    static let empty = SkillPack(version: 0, skills: [])

    /// Degrades to empty rather than throwing. A bundle that failed to copy is
    /// a build problem, and an assistant with no built-in skills still works —
    /// one that will not start does not.
    static func bundled(_ bundle: Bundle = .main, named name: String = "builtin-skills") -> SkillPack {
        guard let url = bundle.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let pack = try? JSONDecoder().decode(SkillPack.self, from: data)
        else { return .empty }
        return pack
    }

    func asSkills() -> [Skill] {
        skills.map { entry in
            Skill(
                id: entry.id,
                title: entry.title,
                whenToUse: entry.whenToUse,
                body: entry.body,
                source: Skill.Source.builtIn
            )
        }
    }
}

// MARK: - Storage

enum SkillRepository {

    /// Everything the assistant may use: what the user or the assistant has
    /// written, plus every built-in that has not been overridden.
    ///
    /// A stored row with a built-in's key wins, unconditionally. It is there
    /// because someone chose to change that skill, and a shipped update has no
    /// business overruling that — it only earns a mention (see `forkedFromBuiltIn`).
    static func all(_ db: Database, builtIn: SkillPack = .bundled()) throws -> [Skill] {
        let stored = try Skill.fetchAll(db, sql: """
            SELECT * FROM skill
            ORDER BY COALESCE(lastUsedAt, updatedAt) DESC
            """)
        let overridden = Set(stored.map(\.id))
        return stored + builtIn.asSkills().filter { !overridden.contains($0.id) }
    }

    static func fetch(_ db: Database, id: String, builtIn: SkillPack = .bundled()) throws -> Skill? {
        if let stored = try Skill.fetchOne(
            db, sql: "SELECT * FROM skill WHERE id = ?", arguments: [id]
        ) { return stored }
        return builtIn.asSkills().first { $0.id == id }
    }

    /// Overrides whose built-in has moved on since they were written.
    ///
    /// Reported rather than merged: the user's edit stands, but they get to
    /// know the shipped one improved instead of quietly running an old fork.
    static func forkedFromBuiltIn(
        _ db: Database, builtIn: SkillPack = .bundled()
    ) throws -> [Skill] {
        let stored = try Skill.fetchAll(db, sql: "SELECT * FROM skill")
        let builtInIDs = Set(builtIn.skills.map(\.id))
        return stored.filter { skill in
            guard builtInIDs.contains(skill.id) else { return false }
            return (skill.basedOnBuiltInVersion ?? 0) < builtIn.version
        }
    }

    @discardableResult
    static func upsert(
        _ db: Database, _ skill: Skill, builtIn: SkillPack = .bundled(), now: Date = Date()
    ) throws -> Bool {
        let existing = try Skill.fetchOne(
            db, sql: "SELECT * FROM skill WHERE id = ?", arguments: [skill.id]
        )
        var record = skill
        record.createdAt = existing?.createdAt ?? skill.createdAt
        record.updatedAt = now
        record.verifiedAt = now
        record.lastUsedAt = existing?.lastUsedAt
        // Writing over a built-in records which version it was written against,
        // so a later shipped improvement can be noticed rather than lost.
        if builtIn.skills.contains(where: { $0.id == skill.id }) {
            record.basedOnBuiltInVersion = builtIn.version
        }
        try record.save(db)
        return existing != nil
    }

    /// Deleting an override restores the built-in, which is the only sensible
    /// reading of "forget this": a shipped skill cannot be deleted, only
    /// replaced or reverted.
    @discardableResult
    static func delete(_ db: Database, id: String) throws -> Bool {
        guard try Skill.fetchOne(
            db, sql: "SELECT * FROM skill WHERE id = ?", arguments: [id]
        ) != nil else { return false }
        try db.execute(sql: "DELETE FROM skill WHERE id = ?", arguments: [id])
        return true
    }

    /// Procedures worth re-checking, oldest first.
    ///
    /// Built-ins are absent by construction — they are not rows — and that is
    /// right: a shipped procedure is refreshed by updating the app, not by
    /// someone confirming it. What the user dictated is excluded in SQL for the
    /// same reason memories are: there is nothing to check it against.
    static func stale(
        _ db: Database,
        asOf now: Date = Date(),
        after days: Int = Memory.staleAfterDays,
        limit: Int = 10
    ) throws -> [Skill] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        return try Skill.fetchAll(db, sql: """
            SELECT * FROM skill
            WHERE source NOT IN (?, ?)
              AND COALESCE(verifiedAt, updatedAt) <= ?
            ORDER BY COALESCE(verifiedAt, updatedAt)
            LIMIT ?
            """, arguments: [Skill.Source.user, Skill.Source.builtIn, cutoff, limit])
    }

    /// Says "these steps still work" without rewriting them. Restating a
    /// procedure to confirm it risks garbling one that was already right, which
    /// is the same reason `confirm_memory` exists.
    @discardableResult
    static func confirm(_ db: Database, id: String, now: Date = Date()) throws -> Bool {
        guard try Skill.fetchOne(
            db, sql: "SELECT * FROM skill WHERE id = ?", arguments: [id]
        ) != nil else { return false }
        try db.execute(
            sql: "UPDATE skill SET verifiedAt = ? WHERE id = ?", arguments: [now, id]
        )
        return true
    }

    static func touch(_ db: Database, id: String, now: Date = Date()) throws {
        try db.execute(
            sql: "UPDATE skill SET lastUsedAt = ? WHERE id = ?", arguments: [now, id]
        )
    }

    // MARK: - Prompt rendering

    /// One line per skill, and only `whenToUse` — the body is what makes a
    /// procedure worth having and also what makes it far too long to load
    /// speculatively. The model spends a call on `get_skill` when the line
    /// says it should.
    static func promptSection(
        _ db: Database,
        builtIn: SkillPack = .bundled(),
        maxEntries: Int = 20
    ) throws -> String {
        let skills = try all(db, builtIn: builtIn)
        guard !skills.isEmpty else { return "" }

        var lines = [
            "## How things are done here",
            "",
            "Call get_skill(\"<key>\") for the steps before doing one of these.",
        ]
        for skill in skills.prefix(maxEntries) {
            lines.append("- [\(skill.id)] \(skill.whenToUse)")
        }
        return lines.joined(separator: "\n")
    }
}
