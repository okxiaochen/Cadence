import Foundation

/// Where `propose_*` tool calls accumulate during a run.
///
/// Tool handlers run on the MCP server's queue, so this is locked. Nothing here
/// reaches the database — the buffer is drained, validated, and reviewed first.
final class ProposalBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var staged: [ProposedChange] = []
    private var summaryText = ""
    private var warningList: [String] = []

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return staged.count
    }

    func stage(_ change: ProposedChange) {
        lock.lock(); defer { lock.unlock() }
        staged.append(change)
    }

    func explain(summary: String, warnings: [String]) {
        lock.lock(); defer { lock.unlock() }
        summaryText = summary
        warningList = warnings
    }

    func drain() -> (changes: [ProposedChange], summary: String, warnings: [String]) {
        lock.lock(); defer { lock.unlock() }
        let result = (staged, summaryText, warningList)
        staged = []
        summaryText = ""
        warningList = []
        return result
    }
}
