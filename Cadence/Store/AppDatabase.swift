import Foundation
import GRDB

/// Owns the SQLite connection and schema. Everything that touches the database
/// goes through the repositories in `Repositories.swift`, which take this.
final class AppDatabase {
    let writer: DatabaseWriter

    init(_ writer: DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
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

        return migrator
    }
}
