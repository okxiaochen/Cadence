#!/usr/bin/env swift
//
// Release signing for Cadence.
//
//   swift scripts/sign-release.swift keygen        # once, prints the public key
//   swift scripts/sign-release.swift sign <file>   # writes <file>.sig
//
// Ed25519 over the raw bytes of the release zip. The private key lives at
// ~/.config/cadence/release-key (mode 600) and never enters the repository;
// the public key is pinned in the app, so an update the key did not sign
// cannot be installed even if the download itself is replaced.

import CryptoKit
import Foundation

let keyURL = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".config/cadence/release-key")

func loadKey() throws -> Curve25519.Signing.PrivateKey {
    let raw = try Data(contentsOf: keyURL)
    guard let decoded = Data(base64Encoded: raw) else {
        throw Failure("release key at \(keyURL.path) is not valid base64")
    }
    return try Curve25519.Signing.PrivateKey(rawRepresentation: decoded)
}

struct Failure: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func keygen() throws {
    if FileManager.default.fileExists(atPath: keyURL.path) {
        let key = try loadKey()
        print("A key already exists at \(keyURL.path) — not overwriting.")
        print("public key: \(key.publicKey.rawRepresentation.base64EncodedString())")
        return
    }

    try FileManager.default.createDirectory(
        at: keyURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let key = Curve25519.Signing.PrivateKey()
    try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: keyURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)

    print("wrote private key to \(keyURL.path) (keep it; back it up somewhere safe)")
    print("public key: \(key.publicKey.rawRepresentation.base64EncodedString())")
    print()
    print("Pin this in Cadence/Update/ReleaseSignature.swift before shipping.")
}

func sign(path: String) throws {
    let key = try loadKey()
    let url = URL(fileURLWithPath: path)
    let payload = try Data(contentsOf: url)
    let signature = try key.signature(for: payload)

    let out = url.appendingPathExtension("sig")
    try Data(signature.base64EncodedString().utf8).write(to: out)
    print("signed \(url.lastPathComponent) → \(out.lastPathComponent)")
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "keygen":
        try keygen()
    case "sign":
        guard arguments.count == 2 else { throw Failure("usage: sign <file>") }
        try sign(path: arguments[1])
    default:
        throw Failure("usage: sign-release.swift [keygen|sign <file>]")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
