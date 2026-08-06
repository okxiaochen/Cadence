import Foundation

struct CLIResult: Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var duration: TimeInterval

    var succeeded: Bool { exitCode == 0 }
}

enum CLIRunnerError: LocalizedError {
    case timedOut(seconds: Int)
    case cancelled
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let seconds): "The AI CLI did not finish within \(seconds)s."
        case .cancelled: "Cancelled."
        case .launchFailed(let message): "Could not start the AI CLI: \(message)"
        }
    }
}

/// Spawns the AI CLI, streams its output, and can always be cancelled.
///
/// Everything here is deliberately observable: the exact argv is recorded, and
/// stdout arrives incrementally so a 60-second run does not look like a hang
/// (AI-INTEGRATION.md §3.3).
final class CLIRunner {

    /// The exact command line that was run, for the run-detail view.
    private(set) var lastCommandLine: String = ""

    private var process: Process?
    private let lock = NSLock()

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL?,
        stdin: String? = nil,
        timeoutSeconds: Int,
        onOutput: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> CLIResult {
        let started = Date()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        // A GUI app's environment is threadbare; give the CLI a usable PATH.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (CLILocator.searchPaths + [environment["PATH"] ?? ""])
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        process.environment = environment

        lastCommandLine = ([executable.path] + arguments)
            .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
            .joined(separator: " ")

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collector = OutputCollector()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            collector.appendStdout(text)
            onOutput(text)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            collector.appendStderr(text)
        }

        lock.lock(); self.process = process; lock.unlock()

        do {
            try process.run()
        } catch {
            cleanUp(outPipe, errPipe)
            throw CLIRunnerError.launchFailed(error.localizedDescription)
        }

        if let stdin {
            let inPipe = Pipe()
            process.standardInput = inPipe
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }

        let timedOut = Timeout()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                    guard !Task.isCancelled, process.isRunning else { return }
                    timedOut.trip()
                    self.terminate()
                }

                process.terminationHandler = { finished in
                    timeoutTask.cancel()
                    self.cleanUp(outPipe, errPipe)
                    self.lock.lock(); self.process = nil; self.lock.unlock()

                    if timedOut.tripped {
                        continuation.resume(throwing: CLIRunnerError.timedOut(seconds: timeoutSeconds))
                        return
                    }
                    continuation.resume(returning: CLIResult(
                        exitCode: finished.terminationStatus,
                        stdout: collector.stdout,
                        stderr: collector.stderr,
                        duration: Date().timeIntervalSince(started)
                    ))
                }
            }
        } onCancel: {
            self.terminate()
        }
    }

    /// SIGTERM, then SIGKILL if the process ignores it.
    func terminate() {
        lock.lock()
        let running = process
        lock.unlock()
        guard let running, running.isRunning else { return }

        running.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if running.isRunning { kill(running.processIdentifier, SIGKILL) }
        }
    }

    private func cleanUp(_ out: Pipe, _ err: Pipe) {
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
    }
}

/// Output arrives on the pipes' background queues, so accumulation is locked.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = ""
    private var err = ""

    var stdout: String { lock.lock(); defer { lock.unlock() }; return out }
    var stderr: String { lock.lock(); defer { lock.unlock() }; return err }

    func appendStdout(_ text: String) { lock.lock(); out += text; lock.unlock() }
    func appendStderr(_ text: String) { lock.lock(); err += text; lock.unlock() }
}

private final class Timeout: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var tripped: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func trip() { lock.lock(); value = true; lock.unlock() }
}
