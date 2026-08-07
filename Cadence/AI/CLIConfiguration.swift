import Foundation

/// How to invoke the user's AI CLI. Stored in `UserDefaults`; there is no API
/// key anywhere in the app — the CLI carries its own auth (AI-INTEGRATION.md §1).
struct CLIConfiguration: Codable, Equatable {
    var command: String = "claude"
    /// Arguments placed before the prompt. `-p` puts Claude Code in print mode.
    var arguments: [String] = ["-p"]
    var workingDirectory: String = NSHomeDirectory()
    var timeoutSeconds: Int = 120
    var transport: Transport = .mcp

    enum Transport: String, Codable, CaseIterable, Identifiable {
        case mcp, json

        var id: String { rawValue }

        var title: String {
            switch self {
            case .mcp: "MCP over localhost"
            case .json: "JSON in / out"
            }
        }
    }

    static let key = "aiCLIConfiguration"

    static func load(from defaults: UserDefaults = .standard) -> CLIConfiguration {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(CLIConfiguration.self, from: data)
        else { return CLIConfiguration() }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// How a configured command will actually be run.
enum CLIInvocation: Equatable {
    /// A real executable we located on disk. Run directly — no shell involved.
    case executable(URL)
    /// Anything a shell knows about but the filesystem does not: an alias, a
    /// shell function, or a binary on a `PATH` that only exists inside the
    /// user's rc files. Run through their login shell.
    case loginShell(command: String, shell: URL)

    var displayPath: String {
        switch self {
        case .executable(let url): url.path
        case .loginShell(let command, let shell): "\(shell.lastPathComponent) -ilc \u{22}\(command) …\u{22}"
        }
    }
}

/// Finds the CLI binary on disk.
///
/// A GUI app does not inherit the shell's `PATH`, so looking up a bare command
/// name the way a terminal would will usually fail. This searches the places
/// these tools actually install to, then falls back to asking a login shell.
enum CLILocator {

    static let searchPaths = [
        "\(NSHomeDirectory())/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "\(NSHomeDirectory())/.bun/bin",
        "\(NSHomeDirectory())/.npm-global/bin",
        "/usr/bin",
        "/bin"
    ]

    enum LocateError: LocalizedError {
        case notFound(String)
        case notExecutable(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let command):
                "Could not find “\(command)”. Enter its full path in Settings › AI."
            case .notExecutable(let path):
                "“\(path)” is not executable."
            }
        }
    }

    static func resolve(_ command: String) throws -> URL {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw LocateError.notFound(command) }

        // An explicit path is used as given.
        if trimmed.contains("/") {
            let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw LocateError.notExecutable(url.path)
            }
            return url
        }

        let candidates = searchPaths + (ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":").map(String.init) ?? [])

        for directory in candidates {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(trimmed)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        if let fromShell = try? askLoginShell(for: trimmed) { return fromShell }
        throw LocateError.notFound(trimmed)
    }

    /// How to run `command`, falling back to the user's shell for anything the
    /// filesystem cannot resolve.
    ///
    /// Wrappers are commonly an alias or a shell function rather than a file —
    /// `command -v` answers with `alias foo='…'` or just the name, neither of
    /// which is executable — and plenty of installs put the binary on a `PATH`
    /// exported from `.zshrc`. All of those work in a terminal and none of them
    /// resolve to a file, so a shell has to do it.
    static func invocation(for command: String) throws -> CLIInvocation {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw LocateError.notFound(command) }

        if let url = try? resolve(trimmed) { return .executable(url) }

        let shell = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        guard shellKnows(trimmed, shell: shell) else {
            throw LocateError.notFound(trimmed)
        }
        return .loginShell(command: trimmed, shell: shell)
    }

    /// Interactive *and* login: `zsh -lc` alone does not read `.zshrc`, which is
    /// where most people put their `PATH` and every alias they have.
    private static func shellKnows(_ command: String, shell: URL) -> Bool {
        let process = Process()
        process.executableURL = shell
        // `-v` alone misses aliases for the same parse-order reason `eval`
        // exists in the runner, so ask about all three kinds explicitly.
        let probe = "command -v \(shellQuoted(command)) >/dev/null 2>&1"
            + " || alias \(shellQuoted(command)) >/dev/null 2>&1"
            + " || typeset -f \(shellQuoted(command)) >/dev/null 2>&1"
        process.arguments = ["-ilc", probe]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Single-quoted for a shell, with embedded quotes escaped.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Last resort: a login shell knows about version managers and custom paths.
    private static func askLoginShell(for command: String) throws -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "command -v \(command)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty,
            FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path)
    }
}
