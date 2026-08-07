import XCTest
@testable import Cadence

/// Resolving the user's configured command.
///
/// The failure that prompted these: a wrapper (`claude-w`) that runs perfectly
/// in a terminal but could not be found by the app, because it was a shell
/// alias rather than a file.
final class CLILocatorTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func makeExecutable(_ name: String, body: String = "#!/bin/bash\necho ok\n") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: - Direct resolution

    func testAnAbsolutePathResolvesToItself() throws {
        let tool = try makeExecutable("mytool")
        guard case .executable(let url) = try CLILocator.invocation(for: tool.path) else {
            return XCTFail("expected a direct executable")
        }
        XCTAssertEqual(url.path, tool.path)
    }

    func testANonExecutableFileIsRejected() throws {
        let url = directory.appendingPathComponent("notrunnable")
        try "text".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CLILocator.invocation(for: url.path))
    }

    func testAnUnknownCommandIsRejected() {
        XCTAssertThrowsError(
            try CLILocator.invocation(for: "definitely-not-a-real-command-\(UUID().uuidString)")
        )
    }

    func testEmptyIsRejected() {
        XCTAssertThrowsError(try CLILocator.invocation(for: "   "))
    }

    /// `claude` is installed on the development machine; skip elsewhere.
    func testARealToolOnPathResolvesDirectly() throws {
        guard FileManager.default.isExecutableFile(
            atPath: "\(NSHomeDirectory())/.local/bin/claude"
        ) else {
            throw XCTSkip("claude is not installed here")
        }
        guard case .executable = try CLILocator.invocation(for: "claude") else {
            return XCTFail("a real binary should not need a shell")
        }
    }

    // MARK: - Quoting

    /// The shell path interpolates the prompt into a command line, so a task
    /// title containing a quote must not be able to rewrite it.
    func testQuotingNeutralisesEmbeddedQuotes() {
        XCTAssertEqual(CLILocator.shellQuoted("plain"), "'plain'")
        XCTAssertEqual(CLILocator.shellQuoted("it's"), #"'it'\''s'"#)
        XCTAssertEqual(
            CLILocator.shellQuoted("'; rm -rf /; echo '"),
            #"''\''; rm -rf /; echo '\'''"#
        )
    }

    func testQuotedStringsSurviveARoundTripThroughTheShell() throws {
        // The real check: whatever we quote comes back byte-identical.
        for value in ["plain", "with space", "it's", "a\"b", "$HOME", "`whoami`", "a;b|c&d"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", "printf %s \(CLILocator.shellQuoted(value))"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(String(data: data, encoding: .utf8), value, "round trip failed for \(value)")
        }
    }

    // MARK: - Wrappers a terminal can run but the filesystem cannot find

    /// Builds an rc file defining a wrapper three ways, then runs each the way
    /// `CLIRunner` does. This is the bug that started all of it: a wrapper that
    /// works in a terminal and could not be found by the app.
    private func runViaLoginShell(
        command: String,
        arguments: [String],
        home: URL
    ) throws -> (status: Int32, output: String) {
        // Mirrors CLIRunner: command bare so aliases expand, arguments quoted,
        // the whole thing through eval so the rc files have run first.
        let line = ([command] + arguments.map(CLILocator.shellQuoted)).joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ilc", "eval \(CLILocator.shellQuoted(line))"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    private func makeWrapperHome() throws -> URL {
        let home = directory.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try makeExecutable("real-tool", body: "#!/bin/bash\nprintf 'got:%s' \"$*\"\n")
        try """
            export PATH="\(directory.path):$PATH"
            alias wrapper-alias='real-tool --model gpt-5.6'
            wrapper-func() { real-tool --model gpt-5.6 "$@"; }
            """.write(
                to: home.appendingPathComponent(".zshrc"),
                atomically: true,
                encoding: .utf8
            )
        return home
    }

    func testAWrapperDefinedAsAnAliasRuns() throws {
        let home = try makeWrapperHome()
        let result = try runViaLoginShell(
            command: "wrapper-alias", arguments: ["--output-format", "json"], home: home
        )
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("--model gpt-5.6"), result.output)
    }

    func testAWrapperDefinedAsAShellFunctionRuns() throws {
        let home = try makeWrapperHome()
        let result = try runViaLoginShell(
            command: "wrapper-func", arguments: ["--output-format", "json"], home: home
        )
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("--model gpt-5.6"), result.output)
    }

    func testAToolOnAPathExportedFromZshrcRuns() throws {
        let home = try makeWrapperHome()
        let result = try runViaLoginShell(command: "real-tool", arguments: ["hello"], home: home)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("hello"), result.output)
    }

    /// The reason arguments stay quoted even though the command does not.
    func testATitleContainingQuotesCannotRewriteTheCommand() throws {
        let home = try makeWrapperHome()
        let hostile = "'; touch \(directory.path)/pwned; echo '"
        let result = try runViaLoginShell(
            command: "real-tool", arguments: [hostile], home: home
        )
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("pwned").path),
            "argument quoting failed and the shell executed injected text"
        )
    }
}
