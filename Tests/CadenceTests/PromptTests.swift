import XCTest
@testable import Cadence

/// The prompts are the only part of the assistant that ships to every user
/// whatever CLI they point it at — they are compiled in, not configured — so
/// what they promise has to match what the model was actually given.
@MainActor
final class PromptTests: XCTestCase {

    // MARK: - Nothing may describe a tool the model does not have

    /// Worse than saying nothing: the model spends the turn trying to call it
    /// and reports the failure as though the user's data were missing.
    func testWorkItemRulesAreAbsentWhenTheConnectorIsOff() {
        XCTAssertTrue(AgentSession.workItemRules(enabled: false).isEmpty)
    }

    func testTheNightlyPlanNeverMentionsWorkItemsWhenTheConnectorIsOff() {
        let prompt = ScheduledRuns.nightlyPrompt(includingWorkItems: false)
        XCTAssertFalse(prompt.contains("list_work_items"), prompt)
        XCTAssertFalse(prompt.contains("externalID"), prompt)
    }

    func testEveryToolNamedInThePromptsExists() {
        let catalog = ToolCatalog(
            database: try! AppDatabase.inMemory(),
            buffer: ProposalBuffer(),
            context: PlanningContext(
                workdayStartHour: 9, workdayEndHour: 18, includesWeekends: false,
                defaultEstimateMinutes: 30, snapMinutes: 15, busy: []
            ),
            meegle: MeegleClient { _ in Data(#"{"list": []}"#.utf8) }
        )
        let names = Set(catalog.tools().map(\.name))
        let prompts = [
            AgentSession.workItemRules(enabled: true),
            ScheduledRuns.nightlyPrompt(includingWorkItems: true),
            ScheduledRuns.reflectionPrompt
        ].joined(separator: "\n")

        // Anything shaped like a tool call in the prose has to be a real tool.
        for token in prompts.split(whereSeparator: { !$0.isLetter && $0 != "_" }) {
            let word = String(token)
            guard word.contains("_"), word.lowercased() == word else { continue }
            // Field names the prompts also mention, which are not tools.
            guard !["work_items", "start_time", "end_time", "iso_time"].contains(word) else { continue }
            XCTAssertTrue(names.contains(word), "prompt names “\(word)”, which is not a tool")
        }
    }

    // MARK: - What the work-item rules have to say

    func testTheRulesSendTheModelToOverdueFirst() {
        let rules = AgentSession.workItemRules(enabled: true)
        XCTAssertTrue(rules.contains("overdue"), rules)
    }

    /// Without this the second sync makes a duplicate of work already on the
    /// user's plate, which the unique index turns into a failed proposal.
    func testTheRulesInsistOnPassingTheExternalIDThrough() {
        let rules = AgentSession.workItemRules(enabled: true)
        XCTAssertTrue(rules.contains("externalID"), rules)
        XCTAssertTrue(rules.contains("alreadyInCadence"), rules)
    }

    // MARK: - The nightly plan's bargain

    /// The ban on inventing work stands; what lifts is the ban on writing down
    /// something the user is already committed to.
    func testTheNightlyPlanStillForbidsInventingWork() {
        for includingWorkItems in [true, false] {
            let prompt = ScheduledRuns.nightlyPrompt(includingWorkItems: includingWorkItems)
            XCTAssertTrue(
                prompt.localizedCaseInsensitiveContains("do not invent"),
                "the invention ban must survive in both forms"
            )
        }
    }

    func testTheNightlyPlanBoundsHowMuchItImports() {
        let prompt = ScheduledRuns.nightlyPrompt(includingWorkItems: true)
        XCTAssertTrue(prompt.contains("three"), "an unbounded import is not a card you can read")
        XCTAssertTrue(prompt.contains("Do not import the whole list"), prompt)
    }

    func testTheNightlyPlanHasToDeclareWhatItBroughtIn() {
        // Finding work in your list that you cannot place is how a planner
        // loses trust, whether or not it was invented.
        let prompt = ScheduledRuns.nightlyPrompt(includingWorkItems: true)
        XCTAssertTrue(prompt.contains("say which"), prompt)
    }

    // MARK: - The whole of what the assistant is told

    private func session() throws -> AgentSession {
        AgentSession(model: AppModel(database: try AppDatabase.inMemory()))
    }

    func testTheSystemPromptCarriesTheRulesThatCannotBeInferredFromASchema() throws {
        let prompt = try session().systemPrompt(for: .chat)
        // A block that disagrees with its estimate gets silently resolved into
        // something nobody chose.
        XCTAssertTrue(prompt.contains("estimate IS the length of its block"), prompt)
        XCTAssertTrue(prompt.contains("get_estimate_history"), prompt)
        XCTAssertTrue(prompt.contains("find_free_slots"), prompt)
    }

    /// The gap that made half the provenance work idle: `source` was in the
    /// schema and nowhere in the prompt, so everything defaulted to the one
    /// source that never expires.
    func testTheSystemPromptExplainsWhatSourceIsFor() throws {
        let prompt = try session().systemPrompt(for: .chat)
        XCTAssertTrue(prompt.contains("`source`"), prompt)
        XCTAssertTrue(prompt.contains("inferred"), prompt)
        XCTAssertTrue(prompt.contains("UNVERIFIED"), prompt)
    }

    /// Dumps the real prompt for eyeballing. Not an assertion — the point is to
    /// be able to read what actually ships without launching the app.
    func testDumpSystemPrompt() throws {
        let prompt = try session().systemPrompt(for: .nightly)
        if let path = ProcessInfo.processInfo.environment["CADENCE_DUMP_PROMPT"] {
            try prompt.write(toFile: path, atomically: true, encoding: .utf8)
        }
        XCTAssertFalse(prompt.isEmpty)
    }

    // MARK: - When the nightly plan is worth running
    //
    // Found by running it: on a Saturday evening it plans Sunday, and with
    // weekends excluded there is nowhere to put anything — a model call spent
    // on a card that says it could do nothing, two nights in seven.

    private func runs() throws -> ScheduledRuns {
        let model = AppModel(database: try AppDatabase.inMemory())
        return ScheduledRuns(model: model, session: AgentSession(model: model))
    }

    /// 2026-08-15 is a Saturday, 17th a Monday.
    private func evening(_ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(
            from: DateComponents(year: 2026, month: 8, day: day, hour: 22)
        )!
    }

    func testTheNightlyPlanSkipsTheEveOfANonWorkingDay() throws {
        let scheduled = try runs()
        scheduled.nightlyPlanEnabled = true
        XCTAssertFalse(scheduled.isNightlyDue(now: evening(15), worksTomorrow: false))
    }

    func testTheNightlyPlanRunsOnTheEveOfAWorkingDay() throws {
        let scheduled = try runs()
        scheduled.nightlyPlanEnabled = true
        XCTAssertTrue(scheduled.isNightlyDue(now: evening(16), worksTomorrow: true))
    }

    func testTheNightlyPlanStillWaitsForItsHour() throws {
        let scheduled = try runs()
        scheduled.nightlyPlanEnabled = true
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let lunchtime = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 16, hour: 12)
        )!
        XCTAssertFalse(scheduled.isNightlyDue(now: lunchtime, worksTomorrow: true))
    }

    // MARK: - Memory provenance

    func testTheReflectionWorksThroughStaleMemories() {
        let prompt = ScheduledRuns.reflectionPrompt
        XCTAssertTrue(prompt.contains("list_stale_memories"), prompt)
        XCTAssertTrue(prompt.contains("confirm_memory"), prompt)
        XCTAssertTrue(prompt.contains("inferred"), "it has to label what it worked out")
    }
}
