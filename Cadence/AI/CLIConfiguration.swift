import Foundation

/// How to invoke the user's AI CLI. Stored in `UserDefaults`; there is no API
/// key anywhere in the app — the CLI carries its own auth (AI-INTEGRATION.md §1).
struct CLIConfiguration: Codable, Equatable {
    var command: String = "claude"
    /// Arguments placed before the prompt. `-p` puts Claude Code in print mode.
    var arguments: [String] = Preset.claudeCode.arguments
    var workingDirectory: String = NSHomeDirectory()
    var timeoutSeconds: Int = 120
    var transport: Transport = .mcp

    /// Arguments carrying the system prompt, with `{system}` substituted.
    ///
    /// **Empty means prepend it to the prompt instead**, which is the universal
    /// fallback: every CLI takes a prompt, and — verified against their own
    /// `--help` — neither Gemini CLI nor Cursor has a flag for a system prompt.
    /// Without this the prompt Cadence compiles in, which is where every rule
    /// the assistant follows lives, simply would not reach them.
    var systemPromptArguments: [String] = Preset.claudeCode.systemPromptArguments

    /// Arguments handing over the loopback MCP server: `{config}` is the config
    /// file's path, `{tools}` the comma-separated allow-list.
    ///
    /// Empty means this CLI cannot be told about a server on the command line.
    /// Gemini and Cursor both keep theirs in a settings file written by an `mcp`
    /// subcommand, and a settings file cannot follow a port that is new every
    /// run — so for them the answer is the JSON transport, not a worse MCP.
    var mcpArguments: [String] = Preset.claudeCode.mcpArguments

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

    /// Known CLIs, with flags read from each one's own `--help` rather than
    /// guessed. A CLI that is not here is not unsupported — it is `custom`,
    /// and the fields above are what it needs filled in.
    enum Preset: String, CaseIterable, Identifiable, Codable {
        case claudeCode, gemini, cursor, custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .gemini: "Gemini CLI"
            case .cursor: "Cursor Agent"
            case .custom: "Custom"
            }
        }

        var command: String {
            switch self {
            case .claudeCode: "claude"
            case .gemini: "gemini"
            case .cursor: "cursor-agent"
            case .custom: ""
            }
        }

        var arguments: [String] {
            switch self {
            case .claudeCode: ["-p", "--output-format", "json"]
            case .gemini: ["-o", "json"]
            case .cursor: ["-p", "--output-format", "json"]
            case .custom: []
            }
        }

        var systemPromptArguments: [String] {
            switch self {
            case .claudeCode: ["--append-system-prompt", "{system}"]
            // Neither has a flag for it; it rides in the prompt.
            case .gemini, .cursor, .custom: []
            }
        }

        var mcpArguments: [String] {
            switch self {
            case .claudeCode:
                ["--mcp-config", "{config}", "--strict-mcp-config", "--allowed-tools", "{tools}"]
            case .gemini, .cursor, .custom: []
            }
        }

        /// Only Claude Code can be handed a server per run; the others would
        /// have to be pre-configured against a port that does not stay still.
        var transport: Transport {
            switch self {
            case .claudeCode: .mcp
            case .gemini, .cursor, .custom: .json
            }
        }

        var configuration: CLIConfiguration {
            var configuration = CLIConfiguration()
            configuration.command = command
            configuration.arguments = arguments
            configuration.systemPromptArguments = systemPromptArguments
            configuration.mcpArguments = mcpArguments
            configuration.transport = transport
            return configuration
        }
    }

    /// Which preset this matches, or `custom` once it has been edited away from
    /// all of them. Derived rather than stored, so hand-editing a field cannot
    /// leave the label claiming something the arguments contradict.
    var preset: Preset {
        Preset.allCases.first {
            $0 != .custom && $0.configuration.matchesInvocation(of: self)
        } ?? .custom
    }

    private func matchesInvocation(of other: CLIConfiguration) -> Bool {
        command == other.command
            && arguments == other.arguments
            && systemPromptArguments == other.systemPromptArguments
            && mcpArguments == other.mcpArguments
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

    init() {}

    /// Hand-written because the synthesised decoder throws on a key it has not
    /// seen, and `load` swallows that with `try?` — so adding a field would
    /// have quietly reset every existing user to the defaults, losing whatever
    /// command they had configured. Every field is optional on the way in.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = CLIConfiguration()
        command = try container.decodeIfPresent(String.self, forKey: .command)
            ?? fallback.command
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
            ?? fallback.workingDirectory
        timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
            ?? fallback.timeoutSeconds
        transport = try container.decodeIfPresent(Transport.self, forKey: .transport)
            ?? fallback.transport
        systemPromptArguments = try container
            .decodeIfPresent([String].self, forKey: .systemPromptArguments)
            ?? fallback.systemPromptArguments
        mcpArguments = try container.decodeIfPresent([String].self, forKey: .mcpArguments)
            ?? fallback.mcpArguments

        let stored = try container.decodeIfPresent([String].self, forKey: .arguments)
        // Output format used to be appended in code, so anyone configured
        // before it moved out here has the older default stored. Upgrading it
        // in place keeps their runs on the path the code still takes.
        arguments = (stored == ["-p"] || stored == nil) ? fallback.arguments : stored!
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

        // Only now pay for a login shell: the directories above cover the usual
        // installs without one, and starting an interactive zsh is slow.
        for directory in LoginEnvironment.searchPaths {
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
