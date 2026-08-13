import XCTest
import GRDB
@testable import Cadence

/// What happens to a user's data when they install a new version.
///
/// The app bundle is replaced on update but the database is not — it lives in
/// Application Support. These tests pin down that promise, and the ways it
/// could quietly stop being true.
final class UpgradeTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try DatabaseQueue(configuration: config)
    }

    /// Release builds must never erase on a schema change; only DEBUG does.
    private var releaseMigrator: DatabaseMigrator {
        var migrator = AppDatabase.migrator
        migrator.eraseDatabaseOnSchemaChange = false
        return migrator
    }

    // MARK: - Upgrading

    func testUpgradingKeepsEverythingTheUserHad() throws {
        let queue = try makeQueue()
        var migrator = releaseMigrator

        // Ship-one: the app as it was two schema versions ago.
        try migrator.migrate(queue, upTo: "v3_retire_inbox")

        let project = Project(name: "Cadence")
        let todo = Todo(title: "Survive the update", status: .todo, estimateMinutes: 60)
        try queue.write { db in
            try CatalogRepository.insert(db, project)
            var owned = todo
            owned.projectID = project.id
            try TodoRepository.insert(db, owned)
            let tag = try CatalogRepository.findOrCreateTag(db, named: "important")
            try TodoRepository.setTags(db, taskID: todo.id, tagIDs: [tag.id])
            try db.execute(sql: """
                INSERT INTO time_block (id, taskID, startAt, endAt, isAllDay, source, createdAt)
                VALUES ('b1', ?, '2026-08-10 09:00:00.000', '2026-08-10 10:00:00.000', 0, 'manual',
                        '2026-08-10 08:00:00.000')
                """, arguments: [todo.id])
        }

        // Ship-two: the user installs the current build and launches it.
        try migrator.migrate(queue)

        try queue.read { db in
            let restored = try TodoRepository.fetchDetail(db, id: todo.id)
            XCTAssertEqual(restored?.todo.title, "Survive the update")
            XCTAssertEqual(restored?.todo.estimateMinutes, 60)
            XCTAssertEqual(restored?.project?.name, "Cadence")
            XCTAssertEqual(restored?.tags.map(\.name), ["important"])
            XCTAssertEqual(restored?.blocks.count, 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task"), 1)
        }
    }

    func testUpgradingIsIdempotent() throws {
        let queue = try makeQueue()
        var migrator = releaseMigrator
        try migrator.migrate(queue)

        try queue.write { db in
            try TodoRepository.insert(db, Todo(title: "Only me"))
        }

        // Relaunching the same version must not re-run anything.
        try migrator.migrate(queue)
        try migrator.migrate(queue)

        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task"), 1)
        }
    }

    func testEveryMigrationIsApplied() throws {
        let queue = try makeQueue()
        var migrator = releaseMigrator
        try migrator.migrate(queue)

        let applied = try queue.read { db in try migrator.appliedIdentifiers(db) }
        XCTAssertEqual(applied, Set(AppDatabase.migrator.migrations))
    }

    // MARK: - Downgrading

    /// Someone who installs a newer build, then reverts to an older one, has a
    /// database carrying migrations the old binary has never heard of.
    ///
    /// Verified behaviour: GRDB does **not** refuse. The old binary ignores the
    /// unknown migration and runs against the newer schema. Data survives, and
    /// because every migration so far only *adds* columns and tables, an old
    /// build still works. That stops being true the moment a migration drops or
    /// renames something a shipped build reads — see RELEASING.md.
    func testDowngradingKeepsDataAndIsTolerated() throws {
        let queue = try makeQueue()
        var migrator = releaseMigrator
        try migrator.migrate(queue)

        try queue.write { db in
            try TodoRepository.insert(db, Todo(title: "Written by a newer build"))
            // Pretend a future release added this.
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99_from_the_future')"
            )
        }

        XCTAssertNoThrow(try migrator.migrate(queue), "an unknown migration is tolerated")

        try queue.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task"), 1,
                "rows written by the newer build must not be lost"
            )
        }
    }

    // MARK: - Damage from outside the app

    /// `sqlite3` on the command line has foreign keys **off** by default, so a
    /// task deleted there leaves its tags and blocks behind. With foreign keys
    /// on — as the app runs — the next migration refuses to proceed, the app
    /// falls back to an in-memory database, and every list looks empty.
    func testALaunchSurvivesOrphansLeftByAnOutsideDelete() throws {
        let path = NSTemporaryDirectory() + "orphan-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }

        var config = Configuration()
        config.foreignKeysEnabled = true
        let database = try AppDatabase(DatabaseQueue(path: path, configuration: config))

        let todo = Todo(title: "Deleted from a shell")
        try database.writer.write { db in
            let inserted = try TodoRepository.insert(db, todo)
            let tag = try CatalogRepository.findOrCreateTag(db, named: "ops")
            try TodoRepository.setTags(db, taskID: inserted.id, tagIDs: [tag.id])
        }

        // What `sqlite3 … "DELETE FROM task …"` does: no cascade.
        var loose = Configuration()
        loose.foreignKeysEnabled = false
        let outside = try DatabaseQueue(path: path, configuration: loose)
        try outside.write { db in
            try db.execute(sql: "DELETE FROM task WHERE id = ?", arguments: [todo.id])
        }
        try outside.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_tag"), 1,
                           "the orphan is there — otherwise this test proves nothing")
        }

        // Relaunch.
        let reopened = try AppDatabase(DatabaseQueue(path: path, configuration: config))
        XCTAssertEqual(reopened.repairedOrphanRows, 1)
        try reopened.writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_tag"), 0)
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testANormalLaunchRepairsNothing() throws {
        let database = try AppDatabase.inMemory()
        XCTAssertEqual(database.repairedOrphanRows, 0)
    }

    // MARK: - The rule that keeps all of the above true

    /// Editing a shipped migration is the one thing that silently breaks
    /// upgrades: users who already ran it never see the change. Guard the set
    /// of identifiers so adding a migration is deliberate and renaming one is
    /// caught here rather than in the field.
    func testShippedMigrationIdentifiersAreStable() {
        XCTAssertEqual(
            AppDatabase.migrator.migrations,
            [
                "v1_core",
                "v2_ai_run",
                "v3_retire_inbox",
                "v4_external_event_id",
                "v5_memory",
                "v6_progress",
                "v7_release_timed_doing",
                "v8_progress_external_event_id",
                "v9_ai_conversation"
            ],
            "A shipped migration was renamed or removed. Add a new one instead — "
                + "users who already ran the old one will never re-run it."
        )
    }
}
