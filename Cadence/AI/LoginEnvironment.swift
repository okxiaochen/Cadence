import Foundation

/// The environment a terminal would have given the CLI.
///
/// A GUI app is started by `launchd`, not by a shell, so it inherits none of
/// `.zshrc`: no `PATH` from nvm/fnm/volta/mise, no `ANTHROPIC_*`, no corporate
/// proxy settings. Finding the configured command on disk is therefore only
/// half the job — the thing people configure here is usually a *wrapper*, and a
/// wrapper goes looking for its own dependencies. Run it with a threadbare
/// environment and it reports the tool as missing ("claude not installed…")
/// even though the identical command works in Terminal.
///
/// So ask the login shell once what it exports and hand that to every run.
/// Only the environment is taken, never the shell's own output: rc files print
/// banners and version notices, and those would otherwise land in the JSON we
/// parse. The marker is what separates the two.
enum LoginEnvironment {

    /// Captured once. Starting an interactive login shell costs a few hundred
    /// milliseconds, and the answer does not change while the app is running.
    private static let cached: [String: String] = capture()

    static var variables: [String: String] { cached }

    /// The shell's `PATH`, split into directories. Empty if the capture failed.
    static var searchPaths: [String] {
        (cached["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    /// Set by the shell for its own session, and wrong for ours — we choose the
    /// working directory explicitly.
    private static let ignored: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_"]

    private static let marker = "__cadence_env__"

    private static func capture() -> [String: String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Interactive *and* login, for the same reason `CLILocator` uses both:
        // `.zshrc` is where `PATH` and every version manager live, and only an
        // interactive shell reads it.
        process.arguments = ["-ilc", "printf %s \(marker); /usr/bin/env -0"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return [:]
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [:] }
        return parse(data)
    }

    /// `env -0` output, preceded by whatever the rc files decided to print.
    static func parse(_ data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8),
              let start = text.range(of: marker)
        else { return [:] }

        var result: [String: String] = [:]
        for entry in text[start.upperBound...].split(separator: "\0") {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            let name = String(entry[..<separator])
            guard !name.isEmpty, !ignored.contains(name) else { continue }
            result[name] = String(entry[entry.index(after: separator)...])
        }
        return result
    }
}
