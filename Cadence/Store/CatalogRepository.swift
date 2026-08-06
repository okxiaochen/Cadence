import Foundation
import GRDB

/// Projects and tags — the small, mostly-static catalogs the sidebar renders.
enum CatalogRepository {

    // MARK: - Projects

    static func projects(_ db: Database, includeArchived: Bool = false) throws -> [Project] {
        let sql = includeArchived
            ? "SELECT * FROM project ORDER BY sortOrder, name COLLATE NOCASE"
            : "SELECT * FROM project WHERE archivedAt IS NULL ORDER BY sortOrder, name COLLATE NOCASE"
        return try Project.fetchAll(db, sql: sql)
    }

    @discardableResult
    static func insert(_ db: Database, _ project: Project) throws -> Project {
        var project = project
        if project.sortOrder == 0 {
            let max = try Double.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM project") ?? 0
            project.sortOrder = max + 1000
        }
        try project.insert(db)
        return project
    }

    static func update(_ db: Database, _ project: Project) throws {
        try project.update(db)
    }

    static func deleteProject(_ db: Database, id: String) throws {
        try db.execute(sql: "DELETE FROM project WHERE id = ?", arguments: [id])
    }

    /// Open task count per project, for the sidebar badges.
    static func openCountsByProject(_ db: Database) throws -> [String: Int] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT projectID, COUNT(*) AS n FROM task
            WHERE projectID IS NOT NULL AND status IN ('inbox', 'todo', 'doing')
            GROUP BY projectID
            """)
        return rows.reduce(into: [:]) { $0[$1["projectID"] as String] = $1["n"] as Int }
    }

    // MARK: - Tags

    static func tags(_ db: Database) throws -> [Tag] {
        try Tag.fetchAll(db, sql: "SELECT * FROM tag ORDER BY name COLLATE NOCASE")
    }

    /// Case-insensitive lookup, creating the tag if it does not exist. This is
    /// what quick capture's `#tag` token and the AI's `tagNames` both go through.
    static func findOrCreateTag(_ db: Database, named name: String) throws -> Tag {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CatalogError.emptyName }

        if let existing = try Tag.fetchOne(
            db,
            sql: "SELECT * FROM tag WHERE name = ? COLLATE NOCASE",
            arguments: [trimmed]
        ) {
            return existing
        }

        let index = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag") ?? 0
        let tag = Tag(name: trimmed, colorHex: Palette.choices[index % Palette.choices.count])
        try tag.insert(db)
        return tag
    }

    /// Same idea for `@project`, but never creates — quick capture should not
    /// silently spawn projects from a typo. Returns nil when there is no match.
    static func findProject(_ db: Database, named name: String) throws -> Project? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let exact = try Project.fetchOne(
            db,
            sql: "SELECT * FROM project WHERE name = ? COLLATE NOCASE AND archivedAt IS NULL",
            arguments: [trimmed]
        ) {
            return exact
        }
        // Fall back to a prefix match so "@cad" finds "Cadence".
        return try Project.fetchOne(
            db,
            sql: """
                SELECT * FROM project
                WHERE name LIKE ? COLLATE NOCASE AND archivedAt IS NULL
                ORDER BY LENGTH(name) LIMIT 1
                """,
            arguments: ["\(trimmed)%"]
        )
    }

    @discardableResult
    static func insert(_ db: Database, _ tag: Tag) throws -> Tag {
        try tag.insert(db)
        return tag
    }

    static func update(_ db: Database, _ tag: Tag) throws {
        try tag.update(db)
    }

    static func deleteTag(_ db: Database, id: String) throws {
        try db.execute(sql: "DELETE FROM tag WHERE id = ?", arguments: [id])
    }

    static func usageCountsByTag(_ db: Database) throws -> [String: Int] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT tt.tagID AS tagID, COUNT(*) AS n
            FROM task_tag tt JOIN task t ON t.id = tt.taskID
            WHERE t.status IN ('inbox', 'todo', 'doing')
            GROUP BY tt.tagID
            """)
        return rows.reduce(into: [:]) { $0[$1["tagID"] as String] = $1["n"] as Int }
    }
}

enum CatalogError: LocalizedError {
    case emptyName

    var errorDescription: String? {
        switch self {
        case .emptyName: "Name cannot be empty."
        }
    }
}
