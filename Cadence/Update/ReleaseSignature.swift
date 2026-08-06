import CryptoKit
import Foundation

/// Verifies that a downloaded release was signed by the release key.
///
/// Without an Apple Developer ID there is no way to make Gatekeeper trust the
/// app, and no way to prove provenance through the system. This closes the gap
/// for *updates* specifically: the bundle-identifier and version checks catch a
/// corrupt or wrong download, but only a signature catches a substituted one.
/// An attacker who replaces the release asset still cannot produce a signature,
/// because the private key never leaves the maintainer's machine.
///
/// Signing is `scripts/sign-release.swift`; `scripts/release.sh` runs it.
enum ReleaseSignature {

    /// Trusted public keys, base64 raw Ed25519.
    ///
    /// An array rather than a single value so a key can be rotated: publish a
    /// build trusting both old and new, then drop the old one once enough
    /// installs have moved on. Losing the only key means losing the ability to
    /// update existing installs at all.
    static let trustedPublicKeys = [
        "kSquwDMuAqG7AZM+am8xtgavFN1hxI23b7jbk15S77c="
    ]

    /// The asset name carrying the signature for `Cadence-x.y.z-macOS.zip`.
    static func signatureAssetName(for assetName: String) -> String {
        assetName + ".sig"
    }

    static func verify(
        payload: Data,
        base64Signature: String,
        publicKeys: [String] = trustedPublicKeys
    ) -> Bool {
        guard let signature = Data(
            base64Encoded: base64Signature.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else { return false }

        for encoded in publicKeys {
            guard let raw = Data(base64Encoded: encoded),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
            else { continue }
            if key.isValidSignature(signature, for: payload) { return true }
        }
        return false
    }
}
