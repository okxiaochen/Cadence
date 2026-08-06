import Foundation
import GRDB

/// Point-in-time snapshots of the database.
///
/// Replacing the app bundle cannot touch the database — it lives in Application
/// Support. The danger an update actually carries is the *new build's*
/// migrations: they run once, on data that only exists on this machine, and a
/// mistake there is unrecoverable. So a snapshot is taken before every update.
enum DatabaseBackup {

    static let folderName = "Backups"
    /// Enough history to survive a bad update going unnoticed for a few days.
    static let keepCount = 10

    static func folder() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let url = support
            .appendingPathComponent("Cadence", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a consistent single-file copy and returns where it landed.
    ///
    /// `VACUUM INTO` rather than copying the file: it runs inside a read
    /// transaction and folds in the write-ahead log, so the result is complete
    /// even while the app is running. Copying `cadence.sqlite` alone would miss
    /// everything still sitting in the `-wal` file.
    @discardableResult
    static func snapshot(
        _ database: AppDatabase,
        reason: String,
        now: Date = Date()
    ) throws -> URL {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let name = "cadence-\(reason)-\(stamp.string(from: now))"
            .replacingOccurrences(of: ":", with: "")
        let url = try folder().appendingPathComponent("\(name).sqlite")

        // VACUUM INTO refuses to overwrite.
        try? FileManager.default.removeItem(at: url)

        try database.writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
        }

        try prune()
        return url
    }

    static func list() throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: try folder(),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return contents
            .filter { $0.pathExtension == "sqlite" }
            .sorted { lhs, rhs in
                (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                    > (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
            }
    }

    /// Drops the oldest snapshots beyond `keepCount`.
    static func prune(keeping keepCount: Int = keepCount) throws {
        let existing = try list()
        guard existing.count > keepCount else { return }
        for url in existing.dropFirst(keepCount) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Sanity check before an update proceeds: a snapshot that cannot be opened
    /// and read is not a backup.
    static func verify(_ url: URL) throws -> Bool {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in
            guard try db.tableExists("task") else { return false }
            // A well-formed but truncated file still answers COUNT(*).
            return try db.execute(sql: "PRAGMA quick_check") == ()
        }
    }
}
