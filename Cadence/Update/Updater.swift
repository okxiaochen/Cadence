import AppKit
import Foundation
import Observation

/// Checks for a newer release and installs it.
///
/// Data safety is the constraint that shapes this whole type:
///
/// - The database is in Application Support, so swapping the bundle cannot
///   touch it. What *can* lose data is the new build's migrations, so a
///   verified snapshot is taken before every install (`DatabaseBackup`).
/// - The swap moves the old bundle aside before installing and puts it back if
///   anything fails, so a half-finished update never leaves you without an app.
/// - Downgrades are refused. An older binary running newer migrations is the
///   one case where the schema and the code genuinely disagree.
@MainActor
@Observable
final class Updater {

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case downloading(received: Int64, total: Int64)
        case installing
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .installing: true
            default: false
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var lastCheckedAt: Date?
    /// Where the pre-update snapshot went, shown after a successful install.
    private(set) var lastBackupPath: String?

    var checksAutomatically: Bool {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: Key.automatic) }
    }

    private let database: AppDatabase
    private let session: URLSession

    private enum Key {
        static let automatic = "checksForUpdatesAutomatically"
        static let lastChecked = "lastUpdateCheckAt"
        static let skippedVersion = "skippedUpdateVersion"
    }

    init(database: AppDatabase, session: URLSession = .shared) {
        self.database = database
        self.session = session
        self.checksAutomatically = UserDefaults.standard.object(forKey: Key.automatic) as? Bool ?? true
        self.lastCheckedAt = UserDefaults.standard.object(forKey: Key.lastChecked) as? Date
    }

    var currentVersion: SemanticVersion { ReleaseFeed.currentVersion() }

    /// The version the user asked not to be nagged about again.
    private var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: Key.skippedVersion) }
        set { UserDefaults.standard.set(newValue, forKey: Key.skippedVersion) }
    }

    func skip(_ release: AppRelease) {
        skippedVersion = release.tag
        state = .idle
    }

    func dismiss() {
        state = .idle
    }

    // MARK: - Checking

    /// Called at launch. Quiet: never surfaces "up to date" or an error.
    func checkInBackground() async {
        guard checksAutomatically else { return }
        if let lastCheckedAt, Date().timeIntervalSince(lastCheckedAt) < 60 * 60 * 6 { return }
        await check(announcing: false)
    }

    /// Called from the menu. Says something either way.
    func checkNow() async {
        await check(announcing: true)
    }

    private func check(announcing: Bool) async {
        guard !state.isBusy else { return }
        state = .checking

        do {
            var request = URLRequest(url: ReleaseFeed.latestURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Cadence/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ReleaseFeedError.malformed
            }

            let release = try ReleaseFeed.parse(data)
            lastCheckedAt = Date()
            UserDefaults.standard.set(lastCheckedAt, forKey: Key.lastChecked)

            guard release.version > currentVersion else {
                state = announcing ? .upToDate : .idle
                return
            }
            if !announcing, release.tag == skippedVersion {
                state = .idle
                return
            }
            state = .available(release)

        } catch {
            state = announcing ? .failed(error.localizedDescription) : .idle
        }
    }

    // MARK: - Installing

    func install(_ release: AppRelease) async {
        guard !state.isBusy else { return }

        do {
            guard release.version > currentVersion else { throw UpdateError.notNewer }

            // 1. Snapshot first. If anything below goes wrong, or the new build
            //    mangles the schema, this is what the data comes back from.
            let backup = try DatabaseBackup.snapshot(database, reason: "before-\(release.version)")
            guard try DatabaseBackup.verify(backup) else { throw UpdateError.backupUnreadable }
            lastBackupPath = backup.path

            // 2. Download.
            state = .downloading(received: 0, total: Int64(release.byteCount))
            let zip = try await download(release)

            // 3. Verify the signature before anything is unpacked or executed.
            //    This is the only check that catches a *substituted* build
            //    rather than merely a corrupt one.
            state = .installing
            try await verifySignature(of: zip, in: release)

            // 4. Unpack and check it is really Cadence, and really newer.
            let staged = try unpack(zip)
            try validate(staged, against: release)

            // 5. Hand the swap to a script that outlives this process, then quit.
            try scheduleSwap(from: staged, backupPath: backup.path)
            NSApp.terminate(nil)

        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func download(_ release: AppRelease) async throws -> URL {
        var request = URLRequest(url: release.downloadURL)
        request.timeoutInterval = 300

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }

        let expected = http.expectedContentLength > 0
            ? http.expectedContentLength
            : Int64(release.byteCount)
        var data = Data()
        data.reserveCapacity(Int(max(0, expected)))

        for try await byte in bytes {
            data.append(byte)
            // Cheap throttle: repainting on every byte would be absurd.
            if data.count % 262_144 == 0 {
                state = .downloading(received: Int64(data.count), total: expected)
            }
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Cadence-\(release.tag)-\(UUID().uuidString).zip")
        try data.write(to: url)
        return url
    }

    private func verifySignature(of zip: URL, in release: AppRelease) async throws {
        guard let signatureURL = release.signatureURL else {
            throw UpdateError.unsigned
        }
        let (signatureData, response) = try await session.data(from: signatureURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let signature = String(data: signatureData, encoding: .utf8)
        else { throw UpdateError.unsigned }

        let payload = try Data(contentsOf: zip)
        guard ReleaseSignature.verify(payload: payload, base64Signature: signature) else {
            throw UpdateError.badSignature
        }
    }

    private func unpack(_ zip: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.unpackFailed }

        let contents = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.unpackFailed
        }
        return app
    }

    /// The downloaded bundle must be Cadence, and must be the version it
    /// claimed to be. Without Developer ID signing this is the only identity
    /// check available — see the note in RELEASING.md.
    private func validate(_ app: URL, against release: AppRelease) throws {
        guard let bundle = Bundle(url: app) else { throw UpdateError.notCadence }
        guard bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError.notCadence
        }
        let raw = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard let downloaded = SemanticVersion(raw) else { throw UpdateError.notCadence }
        guard downloaded == release.version else { throw UpdateError.versionMismatch }
        guard downloaded > currentVersion else { throw UpdateError.notNewer }
    }

    /// Writes a script that waits for this process to exit, swaps the bundle
    /// with a rollback path, and relaunches.
    private func scheduleSwap(from staged: URL, backupPath: String) throws {
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else { throw UpdateError.notInstalled }

        let script = """
        #!/bin/bash
        set -u
        NEW=$1
        TARGET=$2
        PID=$3
        ASIDE="${TARGET}.old-$$"

        # Wait for the running app to exit so the bundle is not in use.
        for _ in $(seq 1 200); do
          kill -0 "$PID" 2>/dev/null || break
          sleep 0.1
        done

        # Move aside rather than delete: if the install fails we can put it back.
        if ! /bin/mv "$TARGET" "$ASIDE"; then
          /usr/bin/open "$TARGET"
          exit 1
        fi

        if /usr/bin/ditto "$NEW" "$TARGET"; then
          /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
          /bin/rm -rf "$ASIDE"
        else
          # Roll back to the version that was working.
          /bin/rm -rf "$TARGET"
          /bin/mv "$ASIDE" "$TARGET"
        fi

        /usr/bin/open "$TARGET"
        """

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-swap-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            url.path,
            staged.path,
            target.path,
            String(ProcessInfo.processInfo.processIdentifier)
        ]
        try process.run()
    }
}

enum UpdateError: LocalizedError {
    case notNewer
    case notCadence
    case versionMismatch
    case downloadFailed
    case unpackFailed
    case backupUnreadable
    case notInstalled
    case unsigned
    case badSignature

    var errorDescription: String? {
        switch self {
        case .notNewer:
            "That version is not newer than the one you are running."
        case .notCadence:
            "The download was not a Cadence app bundle."
        case .versionMismatch:
            "The download did not contain the version the release advertised."
        case .downloadFailed:
            "The download did not complete."
        case .unpackFailed:
            "The download could not be unpacked."
        case .backupUnreadable:
            "A database snapshot could not be taken, so the update was stopped. "
                + "Your data has not been touched."
        case .notInstalled:
            "Cadence does not appear to be running from an app bundle, so it "
                + "cannot replace itself. Download the update manually."
        case .unsigned:
            "That release is not signed, so it was not installed. Download it "
                + "from GitHub yourself if you trust it."
        case .badSignature:
            "The download was not signed by the Cadence release key and was "
                + "discarded. Nothing has been changed."
        }
    }
}
