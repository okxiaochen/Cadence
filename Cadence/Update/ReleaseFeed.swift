import Foundation

/// A published release, as GitHub describes it.
struct AppRelease: Equatable {
    var version: SemanticVersion
    var tag: String
    var name: String
    var notes: String
    var downloadURL: URL
    var byteCount: Int
    var pageURL: URL
    /// Detached Ed25519 signature over the zip, published alongside it.
    var signatureURL: URL?
}

/// Just enough of semantic versioning to compare two builds. Deliberately
/// strict: anything unparseable is treated as "not newer" rather than guessed
/// at, so a malformed tag can never trigger an update.
struct SemanticVersion: Equatable, Comparable, CustomStringConvertible {
    var major: Int
    var minor: Int
    var patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        // Drop any pre-release or build suffix: 1.2.3-beta.1 → 1.2.3
        text = text.components(separatedBy: CharacterSet(charactersIn: "-+")).first ?? text

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        let numbers = parts.map { Int($0) }
        guard !numbers.contains(nil) else { return nil }

        major = numbers[0]!
        minor = numbers.count > 1 ? numbers[1]! : 0
        patch = numbers.count > 2 ? numbers[2]! : 0
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

enum ReleaseFeedError: LocalizedError {
    case malformed
    case noAsset
    case notNewer

    var errorDescription: String? {
        switch self {
        case .malformed: "The release information could not be read."
        case .noAsset: "That release has no macOS download attached."
        case .notNewer: "Cadence is up to date."
        }
    }
}

enum ReleaseFeed {
    static let latestURL = URL(string: "https://api.github.com/repos/okxiaochen/Cadence/releases/latest")!

    /// Parses GitHub's release JSON. Kept separate from the networking so the
    /// decision "is this an update, and which file" is testable offline.
    static func parse(_ data: Data) throws -> AppRelease {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let version = SemanticVersion(tag),
              let pageString = json["html_url"] as? String,
              let pageURL = URL(string: pageString)
        else { throw ReleaseFeedError.malformed }

        // Drafts and pre-releases are never offered.
        if json["draft"] as? Bool == true || json["prerelease"] as? Bool == true {
            throw ReleaseFeedError.notNewer
        }

        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let asset = macOSAsset(in: assets),
              let urlString = asset["browser_download_url"] as? String,
              let downloadURL = URL(string: urlString),
              downloadURL.scheme == "https"
        else { throw ReleaseFeedError.noAsset }

        let assetName = asset["name"] as? String ?? ""
        let signatureName = ReleaseSignature.signatureAssetName(for: assetName)
        let signatureURL = assets
            .first { ($0["name"] as? String) == signatureName }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap(URL.init(string:))
            .flatMap { $0.scheme == "https" ? $0 : nil }

        return AppRelease(
            version: version,
            tag: tag,
            name: json["name"] as? String ?? tag,
            notes: json["body"] as? String ?? "",
            downloadURL: downloadURL,
            byteCount: asset["size"] as? Int ?? 0,
            pageURL: pageURL,
            signatureURL: signatureURL
        )
    }

    /// The zip that holds the app, ignoring source archives and anything else.
    static func macOSAsset(in assets: [[String: Any]]) -> [String: Any]? {
        assets.first { asset in
            guard let name = (asset["name"] as? String)?.lowercased() else { return false }
            return name.hasSuffix(".zip")
                && name.contains("macos")
                && !name.contains("source")
                && !name.contains("dsym")
        }
    }

    /// The current build, from the bundle.
    static func currentVersion(
        bundle: Bundle = .main
    ) -> SemanticVersion {
        let raw = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        return SemanticVersion(raw) ?? SemanticVersion(major: 0, minor: 0, patch: 0)
    }
}
