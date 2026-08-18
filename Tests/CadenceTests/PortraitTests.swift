import XCTest
import GRDB
@testable import Cadence

/// The pass that reads back what somebody has said and works out who they are.
///
/// Everything here guards a failure that is silent in production: a distiller
/// that quietly reads its own output, a category that has nowhere to put what it
/// found, a run that fires nightly into an empty fortnight.
final class PortraitTests: XCTestCase {

    private var database: AppDatabase!
    private var catalog: ToolCatalog!

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
        catalog = ToolCatalog(
            database: database,
            buffer: ProposalBuffer(),
            context: PlanningContext(
                workdayStartHour: 9, workdayEndHour: 18, includesWeekends: false,
                defaultEstimateMinutes: 30, snapMinutes: 15, busy: []
            )
        )
    }

    // MARK: - Reading conversations back

    /// The loop that would otherwise close: the portrait run concludes
    /// something, writes it, reads its own conclusion back next time as
    /// evidence, and grows more certain of it forever without once touching
    /// what the person actually said.
    func testItCannotReadTheUnattendedRunsIncludingItsOwn() throws {
        try insert(surface: .chat, prompt: "I have been getting back into hiking")
        try insert(surface: .portrait, prompt: "Work out who I am")
        try insert(surface: .nightly, prompt: "Plan tomorrow")
        try insert(surface: .reflection, prompt: "Look back")

        let asked = try turns().map { $0["asked"] as? String ?? "" }
        XCTAssertEqual(asked, ["I have been getting back into hiking"])
    }

    func testAFailedRunIsNotEvidenceOfAnything() throws {
        try insert(surface: .chat, prompt: "this one worked")
        try insert(surface: .chat, prompt: "this one did not", status: .failed)

        let asked = try turns().map { $0["asked"] as? String ?? "" }
        XCTAssertEqual(asked, ["this one worked"])
    }

    func testTurnsOfOneConversationStayTogetherAndInOrder() throws {
        let id = "conversation-1"
        try insert(surface: .chat, prompt: "first", conversationID: id, at: -3600)
        try insert(surface: .chat, prompt: "second", conversationID: id, at: -1800)
        try insert(surface: .chat, prompt: "elsewhere", conversationID: "conversation-2")

        let result = try read()
        XCTAssertEqual(result["count"] as? Int, 2)

        let conversations = result["conversations"] as? [[String: Any]] ?? []
        let grouped = conversations.first { ($0["turns"] as? [[String: Any]])?.count == 2 }
        let asked = (grouped?["turns"] as? [[String: Any]])?.compactMap { $0["asked"] as? String }
        // Oldest first inside a conversation: how something opened is usually
        // what says most about why it was asked.
        XCTAssertEqual(asked, ["first", "second"])
    }

    /// A pasted stack trace says nothing about somebody's character and would
    /// crowd out twenty turns that do.
    func testALongTurnIsTruncatedRatherThanDropped() throws {
        try insert(surface: .chat, prompt: String(repeating: "x", count: 9_000))
        let asked = try turns().first?["asked"] as? String ?? ""
        XCTAssertTrue(asked.count < 2_000, "\(asked.count) characters survived")
        XCTAssertTrue(asked.hasSuffix("(truncated)"), asked.suffix(40).description)
    }

    func testTheModelsWordsComeBackOutOfTheCLIEnvelope() throws {
        try insert(
            surface: .chat, prompt: "what do you think",
            rawOutput: #"{"result": "I think you should sleep"}"#
        )
        XCTAssertEqual(try turns().first?["replied"] as? String, "I think you should sleep")
    }

    // MARK: - Somewhere to put what it finds

    /// Without this category everything learned about somebody away from their
    /// work is filed as a "preference" — which is about how they like work done
    /// — or thrown away. Thrown away is what actually happens.
    func testAnInterestIsAKindOfMemory() throws {
        XCTAssertTrue(Memory.Category.allCases.contains(.interest))

        let saved = try database.writer.write { db -> Memory? in
            try MemoryRepository.upsert(db, Memory(
                id: "hiking", category: Memory.Category.interest.rawValue,
                title: "Hiking", summary: "Used to go often; has not been in months"
            ))
            return try MemoryRepository.fetch(db, id: "hiking")
        }
        XCTAssertEqual(saved?.categoryValue, .interest)
    }

    // MARK: - The prompt

    func testThePromptForbidsWritingDownTheConversationItself() {
        // The failure the whole prompt is shaped around: asked to summarise
        // conversations, a model writes a diary, and a diary is never true a
        // second time.
        let prompt = ScheduledRuns.portraitPrompt
        XCTAssertTrue(prompt.contains("What NOT to write down"), prompt)
        XCTAssertTrue(prompt.contains("is not a fact about me"), prompt)
        XCTAssertTrue(prompt.contains("read_conversations"), prompt)
        XCTAssertTrue(prompt.contains("\"interest\""), prompt)
    }

    /// It writes to memory unreviewed, so what it wrote has to be visible.
    func testItSaysWhatItConcluded() {
        XCTAssertTrue(ScheduledRuns.portraitPrompt.contains("one short line per memory"))
    }

    func testTheOpenerMustNameWhatItKnows() {
        // Unenforced, a model asked to say something personal produces
        // flattery, which is indistinguishable from a horoscope.
        let prompt = PetPrompt.somethingPersonal.prompt
        XCTAssertTrue(prompt.contains("Name the thing you know"), prompt)
        XCTAssertTrue(prompt.contains(PetPrompt.silence), prompt)
        XCTAssertTrue(prompt.contains("search_memories"), prompt)
    }

    // MARK: -

    private func read(_ args: [String: Any] = [:]) throws -> [String: Any] {
        try catalog.call("read_conversations", arguments: args) as? [String: Any] ?? [:]
    }

    private func turns() throws -> [[String: Any]] {
        let conversations = try read()["conversations"] as? [[String: Any]] ?? []
        return conversations.flatMap { $0["turns"] as? [[String: Any]] ?? [] }
    }

    private func insert(
        surface: AISurface,
        prompt: String,
        rawOutput: String = "fine",
        status: AIRun.Status = .succeeded,
        conversationID: String? = nil,
        at offset: TimeInterval = 0
    ) throws {
        try database.writer.write { db in
            try AIRunRepository.insert(db, AIRun(
                surface: surface.rawValue,
                prompt: prompt,
                command: "claude",
                rawOutput: rawOutput,
                status: status.rawValue,
                startedAt: Date().addingTimeInterval(offset),
                conversationID: conversationID
            ))
        }
    }
}
