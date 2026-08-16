import Foundation
import GRDB

/// A command the user has agreed Cadence may run on their behalf, to read one
/// of their own tools.
///
/// The threat this is built against is specific. The assistant reads text other
/// people wrote — ticket descriptions, chat messages, documents — and that text
/// can try to talk it into running something. Review alone does not answer it:
/// people who are asked to approve things habitually approve them.
///
/// So there are two layers, and only one of them is human.
///
/// **The shape is approved, not the intent.** What is stored is a command and
/// an argument template; `{placeholders}` are the only parts that vary, and
/// their values are checked against a charset that cannot express a shell
/// operator or a flag. Attacker-controlled text cannot turn an approved command
/// into a different one, because any difference is a different command and
/// needs approving again.
///
/// **Some commands cannot be approved at all.** A shell or an interpreter takes
/// its program as an argument, so approving one exact argv approves nothing —
/// the argv *is* the program. Those are refused before the user is ever asked,
/// which is the half of the gate that does not depend on anyone reading
/// carefully at nine in the evening.
struct ApprovedCommand: Identifiable, Codable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "approved_command"

    var id: String
    /// Which tool this belongs to — `slack`, `jira`. Groups commands so a
    /// connector can be revoked in one go.
    var connector: String
    var command: String
    /// Literals plus `{placeholder}` slots, stored as JSON.
    var argumentsJSON: String
    /// What the assistant said this was for, shown when approving.
    var purpose: String
    var approvedAt: Date = Date()
    var lastUsedAt: Date?

    var arguments: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(argumentsJSON.utf8))) ?? []
    }

    init(
        id: String = UUID().uuidString,
        connector: String,
        command: String,
        arguments: [String],
        purpose: String
    ) {
        self.id = id
        self.connector = connector
        self.command = command
        self.argumentsJSON = String(
            data: (try? JSONEncoder().encode(arguments)) ?? Data("[]".utf8), encoding: .utf8
        ) ?? "[]"
        self.purpose = purpose
    }

    /// Two commands are the same permission when the command and the template
    /// match exactly. Placeholder *values* are not part of it — that is the
    /// point of a template — but everything around them is.
    var signature: String { ([command] + arguments).joined(separator: "\u{1}") }

    func display(with values: [String: String] = [:]) -> String {
        ([command] + ApprovedCommand.substitute(arguments, with: values))
            .joined(separator: " ")
    }

    static func substitute(_ arguments: [String], with values: [String: String]) -> [String] {
        arguments.map { argument in
            var result = argument
            for (name, value) in values {
                result = result.replacingOccurrences(of: "{\(name)}", with: value)
            }
            return result
        }
    }
}

// MARK: - The gate

enum CommandGate {

    enum Refusal: LocalizedError, Equatable {
        case emptyCommand
        case notAPlainCommand(String)
        case runsArbitraryPrograms(String)
        case unsafePlaceholderValue(name: String, value: String)
        case unfilledPlaceholder(String)

        var errorDescription: String? {
            switch self {
            case .emptyCommand:
                "No command given."
            case .notAPlainCommand(let command):
                "“\(command)” is not a plain command name. Cadence runs a named "
                    + "executable, never a path or anything with shell punctuation in it."
            case .runsArbitraryPrograms(let command):
                "“\(command)” runs whatever it is given, so approving one form of "
                    + "it would approve every other. Call the tool you actually "
                    + "want directly."
            case .unsafePlaceholderValue(let name, let value):
                "The value for {\(name)} (“\(value)”) contains characters that are "
                    + "not allowed in a substituted argument."
            case .unfilledPlaceholder(let name):
                "No value given for {\(name)}."
            }
        }
    }

    /// Commands whose entire purpose is running something else.
    ///
    /// Approving `sh -c "…"` approves nothing, because the interesting part is
    /// the string, and the next string is a different program. No amount of
    /// careful review fixes that, so these never reach review. Ordinary tools
    /// are absent from this list even when they *can* be misused — `git log` is
    /// a reasonable thing to approve, and `git -c alias…` is a different argv
    /// and so a different approval.
    static let runsArbitraryPrograms: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish", "ash",
        "python", "python2", "python3", "node", "nodejs", "deno", "bun",
        "ruby", "perl", "php", "lua", "osascript", "swift", "irb", "tclsh",
        "env", "eval", "exec", "xargs", "nohup", "nice", "command", "builtin",
        "sudo", "su", "doas", "ssh", "scp", "sftp", "telnet", "nc", "ncat",
        "socat", "open", "launchctl", "at", "crontab", "make"
    ]

    /// A bare executable name. No slashes, so no paths; no punctuation a shell
    /// would read as an operator. The command name is the one part `CLIProcess`
    /// leaves unquoted — deliberately, so an alias still expands — so it is the
    /// one part that has to be strict.
    private static let commandPattern = try! NSRegularExpression(
        pattern: "^[A-Za-z0-9][A-Za-z0-9_.+-]*$"
    )

    /// What a substituted value may contain: identifiers, ids, dates, URLs
    /// without punctuation a shell cares about. Notably no leading `-`, so a
    /// value cannot quietly become a flag.
    private static let valuePattern = try! NSRegularExpression(
        pattern: "^[A-Za-z0-9_][A-Za-z0-9_.:/@+=,-]*$"
    )

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    /// Checked before the user is asked. A refusal here is not overridable.
    static func check(command: String, arguments: [String]) throws {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Refusal.emptyCommand }
        guard matches(commandPattern, trimmed) else {
            throw Refusal.notAPlainCommand(trimmed)
        }
        guard !runsArbitraryPrograms.contains(trimmed.lowercased()) else {
            throw Refusal.runsArbitraryPrograms(trimmed)
        }
        _ = arguments
    }

    /// Checked at every call, against values that may have come from text
    /// somebody else wrote.
    static func resolve(
        _ arguments: [String], values: [String: String]
    ) throws -> [String] {
        for (name, value) in values {
            guard matches(valuePattern, value) else {
                throw Refusal.unsafePlaceholderValue(name: name, value: value)
            }
        }
        let resolved = ApprovedCommand.substitute(arguments, with: values)
        // A template slot nobody filled would otherwise be passed through as
        // the literal text `{chat}`, which is not what anyone approved.
        for argument in resolved {
            if let name = placeholderName(in: argument) {
                throw Refusal.unfilledPlaceholder(name)
            }
        }
        return resolved
    }

    static func placeholderNames(in arguments: [String]) -> [String] {
        arguments.compactMap(placeholderName(in:))
    }

    private static func placeholderName(in argument: String) -> String? {
        guard let open = argument.firstIndex(of: "{"),
              let close = argument[open...].firstIndex(of: "}"),
              argument.index(after: open) < close
        else { return nil }
        return String(argument[argument.index(after: open)..<close])
    }
}

// MARK: - Storage

enum ApprovedCommandRepository {

    static func all(_ db: Database) throws -> [ApprovedCommand] {
        try ApprovedCommand.fetchAll(db, sql: """
            SELECT * FROM approved_command ORDER BY connector, approvedAt
            """)
    }

    /// The lookup a call makes: is this exact shape already allowed?
    static func matching(
        _ db: Database, command: String, arguments: [String]
    ) throws -> ApprovedCommand? {
        let wanted = ApprovedCommand(
            connector: "", command: command, arguments: arguments, purpose: ""
        ).signature
        return try all(db).first { $0.signature == wanted }
    }

    @discardableResult
    static func approve(_ db: Database, _ approved: ApprovedCommand) throws -> Bool {
        if let existing = try matching(
            db, command: approved.command, arguments: approved.arguments
        ) {
            try touch(db, id: existing.id)
            return false
        }
        try approved.insert(db)
        return true
    }

    static func touch(_ db: Database, id: String, now: Date = Date()) throws {
        try db.execute(
            sql: "UPDATE approved_command SET lastUsedAt = ? WHERE id = ?",
            arguments: [now, id]
        )
    }

    /// Revoking a connector takes every command that came with it — a
    /// half-revoked tool is worse than either state.
    @discardableResult
    static func revoke(_ db: Database, connector: String) throws -> Int {
        let before = try all(db).count
        try db.execute(
            sql: "DELETE FROM approved_command WHERE connector = ?", arguments: [connector]
        )
        return before - (try all(db).count)
    }

    @discardableResult
    static func revoke(_ db: Database, id: String) throws -> Bool {
        guard try ApprovedCommand.fetchOne(
            db, sql: "SELECT * FROM approved_command WHERE id = ?", arguments: [id]
        ) != nil else { return false }
        try db.execute(sql: "DELETE FROM approved_command WHERE id = ?", arguments: [id])
        return true
    }
}
