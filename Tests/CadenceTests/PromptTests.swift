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

    // MARK: - Memory provenance

    func testTheReflectionWorksThroughStaleMemories() {
        let prompt = ScheduledRuns.reflectionPrompt
        XCTAssertTrue(prompt.contains("list_stale_memories"), prompt)
        XCTAssertTrue(prompt.contains("confirm_memory"), prompt)
        XCTAssertTrue(prompt.contains("inferred"), "it has to label what it worked out")
    }
}
