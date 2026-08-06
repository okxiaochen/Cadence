import XCTest
import CryptoKit
import GRDB
@testable import Cadence

final class UpdaterTests: XCTestCase {

    // MARK: - Version comparison

    func testVersionOrdering() {
        XCTAssertTrue(SemanticVersion("0.2.0")! > SemanticVersion("0.1.9")!)
        XCTAssertTrue(SemanticVersion("1.0.0")! > SemanticVersion("0.99.99")!)
        XCTAssertTrue(SemanticVersion("0.1.10")! > SemanticVersion("0.1.9")!,
                      "10 must beat 9 — string comparison would get this wrong")
        XCTAssertEqual(SemanticVersion("v0.1.0"), SemanticVersion("0.1.0"))
        XCTAssertFalse(SemanticVersion("0.1.0")! > SemanticVersion("0.1.0")!)
    }

    func testShortAndDecoratedVersions() {
        XCTAssertEqual(SemanticVersion("1")?.description, "1.0.0")
        XCTAssertEqual(SemanticVersion("1.2")?.description, "1.2.0")
        XCTAssertEqual(SemanticVersion("1.2.3-beta.1")?.description, "1.2.3")
    }

    func testUnparseableVersionsAreRejectedRatherThanGuessed() {
        // A tag we cannot read must never be treated as an update.
        XCTAssertNil(SemanticVersion("nightly"))
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("1.2.x"))
        XCTAssertNil(SemanticVersion("1.2.3.4"))
    }

    // MARK: - Parsing the feed

    private func feed(
        tag: String = "v0.2.0",
        draft: Bool = false,
        prerelease: Bool = false,
        assets: [[String: Any]]? = nil
    ) -> Data {
        let payload: [String: Any] = [
            "tag_name": tag,
            "name": "Cadence 0.2.0",
            "body": "Fixed things.",
            "draft": draft,
            "prerelease": prerelease,
            "html_url": "https://github.com/okxiaochen/Cadence/releases/tag/\(tag)",
            "assets": assets ?? [[
                "name": "Cadence-0.2.0-macOS.zip",
                "size": 5_000_000,
                "browser_download_url":
                    "https://github.com/okxiaochen/Cadence/releases/download/\(tag)/Cadence-0.2.0-macOS.zip"
            ]]
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    func testParsingARelease() throws {
        let release = try ReleaseFeed.parse(feed())
        XCTAssertEqual(release.version, SemanticVersion("0.2.0"))
        XCTAssertEqual(release.byteCount, 5_000_000)
        XCTAssertEqual(release.downloadURL.scheme, "https")
    }

    func testDraftsAndPrereleasesAreNotOffered() {
        XCTAssertThrowsError(try ReleaseFeed.parse(feed(draft: true)))
        XCTAssertThrowsError(try ReleaseFeed.parse(feed(prerelease: true)))
    }

    func testAReleaseWithoutAMacOSZipIsRejected() {
        XCTAssertThrowsError(try ReleaseFeed.parse(feed(assets: [[
            "name": "Source code.zip",
            "size": 100,
            "browser_download_url": "https://example.com/source.zip"
        ]])))
    }

    func testTheSourceArchiveIsNeverMistakenForTheApp() {
        let picked = ReleaseFeed.macOSAsset(in: [
            ["name": "cadence-source.zip"],
            ["name": "Cadence-0.2.0-macOS.dSYM.zip"],
            ["name": "Cadence-0.2.0-macOS.zip"]
        ])
        XCTAssertEqual(picked?["name"] as? String, "Cadence-0.2.0-macOS.zip")
    }

    func testPlainHTTPDownloadsAreRefused() {
        XCTAssertThrowsError(try ReleaseFeed.parse(feed(assets: [[
            "name": "Cadence-0.2.0-macOS.zip",
            "size": 10,
            "browser_download_url": "http://example.com/Cadence-macOS.zip"
        ]])))
    }

    func testGarbageIsRejected() {
        XCTAssertThrowsError(try ReleaseFeed.parse(Data("not json".utf8)))
        XCTAssertThrowsError(try ReleaseFeed.parse(Data("{}".utf8)))
    }

    // MARK: - Backups

    /// The promise the whole feature rests on: updating cannot lose tasks.
    func testSnapshotCapturesEverythingIncludingUnflushedWrites() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: folder.appendingPathComponent("live.sqlite").path,
                                    configuration: config)
        let database = try AppDatabase(pool)

        try database.writer.write { db in
            for index in 0..<25 {
                try TodoRepository.insert(db, Todo(title: "Task \(index)"))
            }
        }

        let snapshot = try DatabaseBackup.snapshot(database, reason: "test")
        defer { try? FileManager.default.removeItem(at: snapshot) }

        XCTAssertTrue(try DatabaseBackup.verify(snapshot))

        // A plain file copy would miss rows still sitting in the -wal file.
        let restored = try DatabaseQueue(path: snapshot.path)
        let count = try restored.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task")
        }
        XCTAssertEqual(count, 25, "the snapshot must include write-ahead log content")
    }

    func testSnapshotIsAStandaloneDatabase() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try TodoRepository.insert(db, Todo(title: "Alone"))
        }
        let snapshot = try DatabaseBackup.snapshot(database, reason: "standalone")
        defer { try? FileManager.default.removeItem(at: snapshot) }

        // Readable with no sidecar files present.
        let queue = try DatabaseQueue(path: snapshot.path)
        XCTAssertEqual(
            try queue.read { db in try String.fetchOne(db, sql: "SELECT title FROM task") },
            "Alone"
        )
    }

    func testPruningKeepsTheMostRecent() throws {
        let folder = try DatabaseBackup.folder()
        // Start from a clean slate so other tests' snapshots do not interfere.
        for url in try DatabaseBackup.list() { try? FileManager.default.removeItem(at: url) }

        let database = try AppDatabase.inMemory()
        try database.writer.write { db in try TodoRepository.insert(db, Todo(title: "x")) }

        for index in 0..<5 {
            _ = try DatabaseBackup.snapshot(
                database,
                reason: "prune\(index)",
                now: Date().addingTimeInterval(Double(index))
            )
        }
        try DatabaseBackup.prune(keeping: 2)

        let remaining = try DatabaseBackup.list()
        XCTAssertEqual(remaining.count, 2)
        XCTAssertTrue(folder.hasDirectoryPath)

        for url in remaining { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Release signatures

    /// A throwaway key pair, so the tests never touch the real release key.
    private func makeKeyPair() -> (private: Curve25519.Signing.PrivateKey, publicBase64: String) {
        let key = Curve25519.Signing.PrivateKey()
        return (key, key.publicKey.rawRepresentation.base64EncodedString())
    }

    func testAGenuineSignatureVerifies() throws {
        let (key, publicKey) = makeKeyPair()
        let payload = Data("pretend this is a zip".utf8)
        let signature = try key.signature(for: payload).base64EncodedString()

        XCTAssertTrue(ReleaseSignature.verify(
            payload: payload, base64Signature: signature, publicKeys: [publicKey]
        ))
    }

    func testATamperedDownloadIsRejected() throws {
        let (key, publicKey) = makeKeyPair()
        let signature = try key.signature(for: Data("original".utf8)).base64EncodedString()

        // This is the attack the signature exists to stop: the release asset is
        // swapped for something else after it was published.
        XCTAssertFalse(ReleaseSignature.verify(
            payload: Data("substituted".utf8),
            base64Signature: signature,
            publicKeys: [publicKey]
        ))
    }

    func testAnotherKeysSignatureIsRejected() throws {
        let (attacker, _) = makeKeyPair()
        let (_, ourPublicKey) = makeKeyPair()
        let payload = Data("zip".utf8)
        let signature = try attacker.signature(for: payload).base64EncodedString()

        XCTAssertFalse(ReleaseSignature.verify(
            payload: payload, base64Signature: signature, publicKeys: [ourPublicKey]
        ))
    }

    func testGarbageSignaturesAreRejected() {
        let (_, publicKey) = makeKeyPair()
        for bad in ["", "not base64!!", "aGVsbG8="] {
            XCTAssertFalse(ReleaseSignature.verify(
                payload: Data("zip".utf8), base64Signature: bad, publicKeys: [publicKey]
            ), "accepted “\(bad)”")
        }
    }

    func testRotationAcceptsEitherKey() throws {
        let (oldKey, oldPublic) = makeKeyPair()
        let (newKey, newPublic) = makeKeyPair()
        let payload = Data("zip".utf8)

        // A build trusting both keys can install releases signed by either,
        // which is what makes rotating the key possible at all.
        for key in [oldKey, newKey] {
            let signature = try key.signature(for: payload).base64EncodedString()
            XCTAssertTrue(ReleaseSignature.verify(
                payload: payload, base64Signature: signature,
                publicKeys: [oldPublic, newPublic]
            ))
        }
    }

    func testThePinnedKeyIsWellFormed() throws {
        XCTAssertFalse(ReleaseSignature.trustedPublicKeys.isEmpty, "nothing could be verified")
        for encoded in ReleaseSignature.trustedPublicKeys {
            let raw = try XCTUnwrap(Data(base64Encoded: encoded))
            XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: raw))
        }
    }

    func testTheSignatureAssetIsFoundAndNotMistakenForTheApp() throws {
        let release = try ReleaseFeed.parse(feed(assets: [
            [
                "name": "Cadence-0.2.0-macOS.zip",
                "size": 5_000_000,
                "browser_download_url":
                    "https://github.com/okxiaochen/Cadence/releases/download/v0.2.0/Cadence-0.2.0-macOS.zip"
            ],
            [
                "name": "Cadence-0.2.0-macOS.zip.sig",
                "size": 88,
                "browser_download_url":
                    "https://github.com/okxiaochen/Cadence/releases/download/v0.2.0/Cadence-0.2.0-macOS.zip.sig"
            ]
        ]))

        XCTAssertEqual(release.downloadURL.lastPathComponent, "Cadence-0.2.0-macOS.zip")
        XCTAssertEqual(release.signatureURL?.lastPathComponent, "Cadence-0.2.0-macOS.zip.sig")
    }

    func testAReleaseWithoutASignatureIsFlagged() throws {
        // Parsing still succeeds — the updater is what refuses to install it,
        // so the user is told why rather than seeing nothing happen.
        let release = try ReleaseFeed.parse(feed())
        XCTAssertNil(release.signatureURL)
    }
}
