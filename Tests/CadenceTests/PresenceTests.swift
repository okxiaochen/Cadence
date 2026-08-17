import XCTest
@testable import Cadence

/// Time at the desk, and what is worth saying about it.
///
/// The signal is idle time, which is a proxy: reading at the desk looks exactly
/// like having left. So the rules err towards silence — being told to stretch
/// when you already have is the failure that gets a companion switched off.
@MainActor
final class PresenceTests: XCTestCase {

    /// Drives the tracker a minute at a time without a mouse.
    private final class Idle: @unchecked Sendable {
        var seconds: Double = 0
    }

    private func tracker(_ idle: Idle) -> PresenceTracker {
        PresenceTracker { idle.seconds }
    }

    func testMinutesAtTheDeskAccumulate() {
        let idle = Idle()
        let presence = tracker(idle)
        for _ in 0..<30 { presence.tick() }
        XCTAssertEqual(presence.sittingMinutes, 30)
    }

    /// Getting up *is* the break. Nothing needs suggesting afterwards, and the
    /// count starts again when they come back.
    func testGettingUpResetsTheCount() {
        let idle = Idle()
        let presence = tracker(idle)
        for _ in 0..<40 { presence.tick() }
        idle.seconds = Double(PresenceTracker.awayAfterMinutes) * 60
        presence.tick()
        XCTAssertEqual(presence.sittingMinutes, 0)

        idle.seconds = 0
        for _ in 0..<3 { presence.tick() }
        XCTAssertEqual(presence.sittingMinutes, 3)
    }

    /// A pause shorter than the threshold is thinking, not leaving.
    func testAShortPauseIsNotAnAbsence() {
        let idle = Idle()
        let presence = tracker(idle)
        for _ in 0..<20 { presence.tick() }
        idle.seconds = 120
        presence.tick()
        XCTAssertEqual(presence.sittingMinutes, 21)
    }

    /// Water is counted by time present, not wall clock: an afternoon away
    /// should not come back to three glasses owed.
    func testWaterIsCountedInTimePresent() {
        let idle = Idle()
        let presence = tracker(idle)
        for _ in 0..<10 { presence.tick() }
        idle.seconds = 600
        for _ in 0..<100 { presence.tick() }
        XCTAssertEqual(presence.minutesSinceWater, 10)
    }

    // MARK: - What gets said

    func testNothingIsSaidBeforeTheThreshold() {
        XCTAssertEqual(
            PetNudge.decide(sittingMinutes: 20, minutesSinceWater: 20,
                            moveAfter: 50, waterAfter: 90, lastNudgedAt: nil),
            .none
        )
    }

    func testSittingTooLongIsWorthSaying() {
        XCTAssertEqual(
            PetNudge.decide(sittingMinutes: 55, minutesSinceWater: 10,
                            moveAfter: 50, waterAfter: 90, lastNudgedAt: nil),
            .move(sittingMinutes: 55)
        )
    }

    /// Getting up usually solves the other one anyway.
    func testStandingUpOutranksWater() {
        XCTAssertEqual(
            PetNudge.decide(sittingMinutes: 55, minutesSinceWater: 200,
                            moveAfter: 50, waterAfter: 90, lastNudgedAt: nil),
            .move(sittingMinutes: 55)
        )
    }

    func testItDoesNotRepeatItselfInsideTheCooldown() {
        let now = Date()
        XCTAssertEqual(
            PetNudge.decide(sittingMinutes: 200, minutesSinceWater: 200,
                            moveAfter: 50, waterAfter: 90,
                            lastNudgedAt: now.addingTimeInterval(-60), now: now),
            .none
        )
    }

    func testZeroTurnsEachOneOff() {
        XCTAssertEqual(
            PetNudge.decide(sittingMinutes: 500, minutesSinceWater: 500,
                            moveAfter: 0, waterAfter: 0, lastNudgedAt: nil),
            .none
        )
        XCTAssertEqual(
            PetNudge.decide(sittingMinutes: 500, minutesSinceWater: 500,
                            moveAfter: 0, waterAfter: 90, lastNudgedAt: nil),
            .water(afterMinutes: 500)
        )
    }

    /// "Had one" has to actually clear it, or the reminder is a nag with a
    /// button on it.
    func testSayingYouHadWaterClearsTheCount() {
        let idle = Idle()
        let presence = tracker(idle)
        for _ in 0..<120 { presence.tick() }
        presence.noteWater()
        XCTAssertEqual(presence.minutesSinceWater, 0)
    }
}
