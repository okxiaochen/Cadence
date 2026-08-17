import XCTest
@testable import Cadence

/// When a saved question runs on its own, and — more importantly — when it
/// does not.
final class ScheduledPromptTests: XCTestCase {

    private func prompt(every minutes: Int?, lastRun: Date? = nil) -> PetPrompt {
        var saved = PetPrompt(title: "Weather", prompt: "check the weather")
        saved.everyMinutes = minutes
        saved.lastRunAt = lastRun
        return saved
    }

    // MARK: - Due-ness

    func testAButtonWithNoCadenceNeverRunsItself() {
        XCTAssertFalse(prompt(every: nil).isScheduled)
        XCTAssertFalse(prompt(every: nil).isDue())
        XCTAssertFalse(prompt(every: 0).isDue())
    }

    func testSomethingNeverRunIsDueImmediately() {
        XCTAssertTrue(prompt(every: 120).isDue())
    }

    func testItWaitsOutItsInterval() {
        let now = Date()
        XCTAssertFalse(prompt(every: 120, lastRun: now.addingTimeInterval(-60 * 60)).isDue(now: now))
        XCTAssertTrue(prompt(every: 120, lastRun: now.addingTimeInterval(-121 * 60)).isDue(now: now))
    }

    /// Stored, so relaunching the app is not a way to make a four-hour check
    /// happen four times an hour.
    func testTheIntervalSurvivesARelaunch() throws {
        let saved = [prompt(every: 240, lastRun: Date(timeIntervalSince1970: 1_700_000_000))]
        let restored = [PetPrompt].decoded(from: saved.encoded)
        XCTAssertEqual(restored.first?.lastRunAt, saved.first?.lastRunAt)
        XCTAssertEqual(restored.first?.everyMinutes, 240)
    }

    // MARK: - Silence

    /// Something has to mean "nothing worth saying", or a cadence is a
    /// guarantee of noise.
    func testTheAgreedWordMeansSayNothing() {
        XCTAssertTrue(PetPrompt.isSilent("SKIP"))
        XCTAssertTrue(PetPrompt.isSilent("  skip  "))
        XCTAssertTrue(PetPrompt.isSilent("SKIP — nothing changed since this morning."))
    }

    /// An empty reply is indistinguishable from a failure, so it is silence
    /// too rather than an empty bubble.
    func testAnEmptyReplyIsAlsoSilence() {
        XCTAssertTrue(PetPrompt.isSilent(""))
        XCTAssertTrue(PetPrompt.isSilent("\n  \n"))
    }

    func testARealAnswerIsNotSilence() {
        XCTAssertFalse(PetPrompt.isSilent("Rain expected from 4pm — the walk may not happen."))
        // A word that merely contains it is not the word.
        XCTAssertFalse(PetPrompt.isSilent("The skipper resigned this morning."))
    }

    // MARK: - What gets sent

    /// Appended rather than left to the user to remember: forgetting it is
    /// what turns a cadence into a guarantee of noise, and nobody writing a
    /// one-line prompt would think to include it.
    @MainActor
    func testTheSilenceInstructionIsAddedForThem() {
        let sent = ScheduledPrompts.wrap("check the weather")
        XCTAssertTrue(sent.hasPrefix("check the weather"))
        XCTAssertTrue(sent.contains(PetPrompt.silence))
        XCTAssertTrue(sent.localizedCaseInsensitiveContains("earn the interruption"))
    }
}
