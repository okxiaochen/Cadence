import Foundation

/// Runs one of the user's own CLIs and waits for it.
///
/// Shared by every connector, because the reason for shelling out is the same
/// each time: the CLI already holds a user OAuth token in the OS keychain, so
/// the call runs as that person with exactly their visibility, and Cadence
/// never holds a credential.
///
/// Blocking on purpose. `ToolCatalog.call` is synchronous all the way to the
/// socket and the model is waiting for the answer regardless. What blocking
/// demands is the timeout: a wedged CLI would otherwise wedge the connection's
/// queue with it.
struct CLIProcess {

    let invocation: CLIInvocation
    var timeoutSeconds: Int = 30

    enum Failure: LocalizedError, Equatable {
        case notInstalled(String)
        case timedOut(command: String, seconds: Int)
        case failed(command: String, message: String)

        var errorDescription: String? {
            switch self {
            case .notInstalled(let command): "The \(command) CLI was not found."
            case .timedOut(let command, let seconds):
                "\(command) did not answer within \(seconds)s."
            case .failed(let command, let message): "\(command) failed: \(message)"
            }
        }
    }

    /// Fails when the command is not on the user's path — including the paths
    /// that exist only inside their shell's rc files, which `CLILocator` covers.
    init(command: String, timeoutSeconds: Int = 30) throws {
        guard let invocation = try? CLILocator.invocation(for: command) else {
            throw Failure.notInstalled(command)
        }
        self.invocation = invocation
        self.timeoutSeconds = timeoutSeconds
    }

    func run(_ arguments: [String], named command: String) throws -> Data {
        let process = Process()
        switch invocation {
        case .executable(let url):
            process.executableURL = url
            process.arguments = arguments

        case .loginShell(let shellCommand, let shell):
            // The command bare so an alias still expands, every argument
            // quoted, the whole line under `eval` because zsh parses `-c`
            // before the rc files have defined anything. AI-INTEGRATION.md §7.
            let line = ([shellCommand] + arguments.map(CLILocator.shellQuoted))
                .joined(separator: " ")
            process.executableURL = shell
            process.arguments = ["-ilc", "eval \(CLILocator.shellQuoted(line))"]
        }

        // A GUI app's environment has no rc file behind it, so a CLI installed
        // by a version manager would not find its own runtime.
        var environment = ProcessInfo.processInfo.environment
            .merging(LoginEnvironment.variables) { _, fromShell in fromShell }
        var seen = Set<String>()
        environment["PATH"] = (LoginEnvironment.searchPaths
            + (environment["PATH"]?.split(separator: ":").map(String.init) ?? [])
            + CLILocator.searchPaths)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do { try process.run() } catch {
            throw Failure.failed(command: command, message: error.localizedDescription)
        }

        // Both pipes are drained on their own queues *before* waiting. Reading
        // after `waitUntilExit` deadlocks as soon as the output outgrows the
        // pipe buffer, and a page of results comfortably does.
        let out = Collector()
        let err = Collector()
        let group = DispatchGroup()
        for (pipe, sink) in [(outPipe, out), (errPipe, err)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                sink.append(pipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
        }

        let timedOut = Flag()
        let watchdog = DispatchWorkItem { [weak process] in
            timedOut.set()
            process?.terminate()
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .seconds(timeoutSeconds), execute: watchdog
        )

        process.waitUntilExit()
        group.wait()
        watchdog.cancel()

        if timedOut.value {
            throw Failure.timedOut(command: command, seconds: timeoutSeconds)
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: err.data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure.failed(
                command: command,
                message: message.isEmpty ? "exit \(process.terminationStatus)" : message
            )
        }
        return out.data
    }
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ chunk: Data) { lock.lock(); storage.append(chunk); lock.unlock() }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool { lock.lock(); defer { lock.unlock() }; return storage }
    func set() { lock.lock(); storage = true; lock.unlock() }
}
