import Foundation
import GRDB

/// Owns the SQLite connection and schema. Everything that touches the database
/// goes through the repositories in `Repositories.swift`, which take this.
final class AppDatabase {
    let writer: DatabaseWriter

    /// Rows deleted at startup — see `repairOrphans`. Zero on every normal
    /// launch; surfaced when it is not, because data was removed.
    private(set) var repairedOrphanRows: Int

    init(_ writer: DatabaseWriter) throws {
        self.writer = writer
        // Before migrating, not after a failure: a migration runs with foreign
        // keys on and refuses to proceed while the database violates them, but
        // a launch with nothing to migrate would sail past the damage and break
        // on some later release instead — a long way from the cause.
        //
        // The damage comes from outside: `sqlite3` on the command line has
        // foreign keys *off* by default, so anyone (or any script, or any
        // agent) deleting a task there leaves its tags and blocks behind. The
        // app then falls back to an in-memory database and looks, convincingly,
        // like it lost everything.
        repairedOrphanRows = (try? Self.repairOrphans(writer)) ?? 0
        try Self.migrator.migrate(writer)
    }

    /// Deletes rows whose parent no longer exists.
    ///
    /// Driven by `foreign_key_check` rather than a hand-written list of tables,
    /// so a table added later is covered without anyone remembering to come
    /// back here. These rows are unreachable by definition — nothing can read
    /// them, since the task they hang off is gone.
    @discardableResult
    static func repairOrphans(_ writer: DatabaseWriter) throws -> Int {
        try writer.write { db in
            let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
            guard !violations.isEmpty else { return 0 }

            var byTable: [String: [Int64]] = [:]
            for row in violations {
                guard let table: String = row[0], let rowID: Int64 = row[1] else { continue }
                byTable[table, default: []].append(rowID)
            }

            var deleted = 0
            for (table, rowIDs) in byTable {
                // The table name comes from SQLite's own pragma, not from user
                // input, so quoting it is enough.
                let placeholders = placeholders(rowIDs.count)
                try db.execute(
                    sql: "DELETE FROM \"\(table)\" WHERE rowid IN (\(placeholders))",
                    arguments: StatementArguments(rowIDs)
                )
                deleted += db.changesCount
            }
            return deleted
        }
    }

    /// The real on-disk database: ~/Library/Application Support/Cadence/cadence.sqlite
    static func onDisk() throws -> AppDatabase {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = support.appendingPathComponent("Cadence", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("cadence.sqlite")

        var config = Configuration()
        config.foreignKeysEnabled = true
        #if DEBUG
        config.publicStatementArguments = true
        #endif

        let pool = try DatabasePool(path: url.path, configuration: config)
        return try AppDatabase(pool)
    }

    /// A throwaway in-memory database, for tests and previews.
    static func inMemory() throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try AppDatabase(DatabaseQueue(configuration: config))
    }

    // MARK: - Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        // Off by default. This wipes the database whenever the schema changes,
        // which shares a file with the installed app — convenient while the
        // schema was in flux, data loss now that it holds real tasks.
        // Opt in per-run when it is genuinely wanted:
        //     CADENCE_RESET_DB=1 xcodebuild …
        migrator.eraseDatabaseOnSchemaChange =
            ProcessInfo.processInfo.environment["CADENCE_RESET_DB"] == "1"
        #endif

        migrator.registerMigration("v1_core") { db in
            try db.execute(sql: """
                CREATE TABLE project (
                  id          TEXT PRIMARY KEY,
                  name        TEXT NOT NULL,
                  colorHex    TEXT NOT NULL,
                  symbolName  TEXT,
                  sortOrder   REAL NOT NULL DEFAULT 0,
                  archivedAt  TEXT
                );

                CREATE TABLE tag (
                  id       TEXT PRIMARY KEY,
                  name     TEXT NOT NULL UNIQUE COLLATE NOCASE,
                  colorHex TEXT NOT NULL
                );

                CREATE TABLE task (
                  id              TEXT PRIMARY KEY,
                  title           TEXT NOT NULL,
                  notes           TEXT NOT NULL DEFAULT '',
                  status          TEXT NOT NULL DEFAULT 'inbox',
                  priority        INTEGER NOT NULL DEFAULT 0,
                  estimateMinutes INTEGER,
                  projectID       TEXT REFERENCES project(id) ON DELETE SET NULL,
                  parentID        TEXT REFERENCES task(id)    ON DELETE CASCADE,
                  dueAt           TEXT,
                  deferAt         TEXT,
                  sortOrder       REAL NOT NULL DEFAULT 0,
                  createdAt       TEXT NOT NULL,
                  updatedAt       TEXT NOT NULL,
                  completedAt     TEXT
                );
                CREATE INDEX idx_task_status  ON task(status);
                CREATE INDEX idx_task_project ON task(projectID);
                CREATE INDEX idx_task_parent  ON task(parentID);
                CREATE INDEX idx_task_due     ON task(dueAt);

                CREATE TABLE task_tag (
                  taskID TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
                  tagID  TEXT NOT NULL REFERENCES tag(id)  ON DELETE CASCADE,
                  PRIMARY KEY (taskID, tagID)
                );
                CREATE INDEX idx_task_tag_tag ON task_tag(tagID);

                CREATE TABLE time_block (
                  id        TEXT PRIMARY KEY,
                  taskID    TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
                  startAt   TEXT NOT NULL,
                  endAt     TEXT NOT NULL,
                  isAllDay  INTEGER NOT NULL DEFAULT 0,
                  source    TEXT NOT NULL DEFAULT 'manual',
                  createdAt TEXT NOT NULL
                );
                CREATE INDEX idx_block_range ON time_block(startAt, endAt);
                CREATE INDEX idx_block_task  ON time_block(taskID);
                """)
        }

        // M3 lands `ai_run` here; the table is unused until then.
        migrator.registerMigration("v2_ai_run") { db in
            try db.execute(sql: """
                CREATE TABLE ai_run (
                  id          TEXT PRIMARY KEY,
                  surface     TEXT NOT NULL,
                  prompt      TEXT NOT NULL,
                  command     TEXT NOT NULL,
                  rawOutput   TEXT NOT NULL DEFAULT '',
                  status      TEXT NOT NULL,
                  startedAt   TEXT NOT NULL,
                  finishedAt  TEXT,
                  appliedDiff TEXT
                );
                """)
        }

        // The sidebar no longer has an Inbox, so untriaged rows become todos.
        migrator.registerMigration("v3_retire_inbox") { db in
            try db.execute(sql: "UPDATE task SET status = 'todo' WHERE status = 'inbox'")
        }

        // M4: one-way publish into a dedicated Apple Calendar.
        migrator.registerMigration("v4_external_event_id") { db in
            try db.execute(sql: "ALTER TABLE time_block ADD COLUMN externalEventID TEXT")
        }

        // M5: durable facts the assistant may consult when planning.
        migrator.registerMigration("v5_memory") { db in
            try db.execute(sql: """
                CREATE TABLE memory (
                  id         TEXT PRIMARY KEY,
                  category   TEXT NOT NULL,
                  title      TEXT NOT NULL,
                  summary    TEXT NOT NULL,
                  body       TEXT NOT NULL DEFAULT '',
                  pinned     INTEGER NOT NULL DEFAULT 0,
                  createdAt  TEXT NOT NULL,
                  updatedAt  TEXT NOT NULL,
                  lastUsedAt TEXT
                );
                CREATE INDEX idx_memory_recency ON memory(pinned, lastUsedAt, updatedAt);
                """)
        }

        // M6: what actually happened on a task, as against what was planned.
        //
        // One timeline per task holding two kinds of entry: a `session` with a
        // start and (once stopped) an end, and a `note` — a line of "here is
        // where I got to" with no duration. Deliberately its own table rather
        // than more `time_block` rows: a block is a *plan*, and a task still
        // has at most one of those (see TodoRepository).
        migrator.registerMigration("v6_progress") { db in
            try db.execute(sql: """
                CREATE TABLE progress_entry (
                  id        TEXT PRIMARY KEY,
                  taskID    TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
                  kind      TEXT NOT NULL DEFAULT 'note',
                  note      TEXT NOT NULL DEFAULT '',
                  startedAt TEXT NOT NULL,
                  endedAt   TEXT,
                  createdAt TEXT NOT NULL
                );
                CREATE INDEX idx_progress_task  ON progress_entry(taskID, startedAt);
                CREATE INDEX idx_progress_range ON progress_entry(startedAt, endedAt);
                """)
        }

        // M7: undo the damage from the version where starting a timer set a
        // task to `doing`. Nothing ever set it back, and Today matches
        // `doing` — so every task that was ever timed had moved into Today for
        // good. Only tasks that actually have a timeline are touched: a `doing`
        // the user set by hand on a task they never timed is theirs to keep.
        migrator.registerMigration("v7_release_timed_doing") { db in
            try db.execute(sql: """
                UPDATE task SET status = 'todo'
                WHERE status = 'doing'
                  AND EXISTS (SELECT 1 FROM progress_entry p WHERE p.taskID = task.id)
                """)
        }

        // M8: recorded sessions can be published to Apple Calendar too, so they
        // need the same pairing column blocks have.
        migrator.registerMigration("v8_progress_external_event_id") { db in
            try db.execute(sql: "ALTER TABLE progress_entry ADD COLUMN externalEventID TEXT")
        }

        // M9: runs belong to a conversation, so the panel can be cleared,
        // reopened, and looked back over.
        migrator.registerMigration("v9_ai_conversation") { db in
            try db.execute(sql: "ALTER TABLE ai_run ADD COLUMN conversationID TEXT")
            // Everything that already ran becomes its own conversation rather
            // than one enormous history with no boundaries in it.
            try db.execute(sql: "UPDATE ai_run SET conversationID = id WHERE conversationID IS NULL")
        }

        // M10: where a task came from, when it did not come from the user.
        //
        // Namespaced (`meegle:<space>:<id>`) rather than bare, so a second
        // connector cannot collide with the first. The index is unique but the
        // column is nullable, and SQLite treats NULLs as distinct — so every
        // hand-made task stays unconstrained while an imported one can only
        // exist once. That uniqueness is the whole point: it is what makes a
        // re-sync revise the task it already made instead of adding another.
        migrator.registerMigration("v10_task_external_id") { db in
            try db.execute(sql: "ALTER TABLE task ADD COLUMN externalID TEXT")
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_task_external ON task(externalID)
                WHERE externalID IS NOT NULL
                """)
        }

        // M11: where a memory came from, and when it was last checked.
        //
        // The pair is what makes a knowledge base maintainable rather than
        // merely growing. `upsert` already self-corrects on write, but nothing
        // ever revisits a memory nobody happens to write to again, and a fact
        // read out of another system is exactly the kind that quietly stops
        // being true.
        //
        // Source decides whether staleness even applies: something the user
        // said stays true until they say otherwise, because there is nothing to
        // re-check it against. Something inferred from their records, or read
        // out of Meegle, describes a world that moves.
        //
        // Existing rows are backfilled as self-reported and verified when they
        // were last written. Which of them were really inferred cannot be
        // recovered, and marking them all stale would bury the first review in
        // re-checks of things that are probably fine.
        migrator.registerMigration("v11_memory_provenance") { db in
            try db.execute(sql: """
                ALTER TABLE memory ADD COLUMN source TEXT NOT NULL DEFAULT 'user'
                """)
            try db.execute(sql: "ALTER TABLE memory ADD COLUMN verifiedAt TEXT")
            try db.execute(sql: "UPDATE memory SET verifiedAt = updatedAt")
        }

        // M12: procedures, as against the facts in `memory`.
        //
        // The table holds only what the user or the assistant wrote. Built-in
        // skills are read from the app bundle and never inserted here, which is
        // what makes shipping a better version of one a no-op: there is no
        // stored copy to reconcile with. A row with a built-in's key overrides
        // it, and records the version it was written against so the fork can be
        // noticed later without being overruled.
        migrator.registerMigration("v12_skill") { db in
            try db.execute(sql: """
                CREATE TABLE skill (
                  id                    TEXT PRIMARY KEY,
                  title                 TEXT NOT NULL,
                  whenToUse             TEXT NOT NULL,
                  body                  TEXT NOT NULL DEFAULT '',
                  source                TEXT NOT NULL DEFAULT 'user',
                  createdAt             TEXT NOT NULL,
                  updatedAt             TEXT NOT NULL,
                  verifiedAt            TEXT,
                  lastUsedAt            TEXT,
                  basedOnBuiltInVersion INTEGER
                );
                CREATE INDEX idx_skill_recency ON skill(lastUsedAt, updatedAt);
                """)
        }

        // M13: commands the user has agreed Cadence may run to read their own
        // tools.
        //
        // Its own table rather than a field on `skill` on purpose. A skill is
        // prose the assistant may rewrite at will; this is a permission, and
        // the two must not share a write path — otherwise a model that can
        // revise a procedure can widen what it is allowed to run.
        migrator.registerMigration("v13_approved_command") { db in
            try db.execute(sql: """
                CREATE TABLE approved_command (
                  id            TEXT PRIMARY KEY,
                  connector     TEXT NOT NULL,
                  command       TEXT NOT NULL,
                  argumentsJSON TEXT NOT NULL,
                  purpose       TEXT NOT NULL DEFAULT '',
                  approvedAt    TEXT NOT NULL,
                  lastUsedAt    TEXT
                );
                CREATE INDEX idx_approved_connector ON approved_command(connector);
                """)
        }

        return migrator
    }
}
