import XCTest
@testable import Cadence

/// The companion's artwork, and the rule that keeps it cheap.
@MainActor
final class CatArtworkTests: XCTestCase {

    private let moods: [PetStatus.Mood] = [.idle, .working, .restDue, .behind, .clear]

    /// Every mood has to have *something* to draw. The fallback chain means a
    /// missing file is never a blank window, which is exactly why a missing
    /// file would otherwise go unnoticed until somebody's day went quiet.
    func testEveryMoodHasArtwork() {
        for mood in moods {
            let animated = CatArtwork.animation(named: mood.assetName) != nil
            let still = NSImage(named: mood.assetName) != nil
            XCTAssertTrue(animated || still, "no artwork for \(mood)")
        }
    }

    func testAnimationsHaveSeveralFramesAndSaneTiming() {
        for mood in moods {
            guard let animation = CatArtwork.animation(named: mood.assetName) else { continue }
            XCTAssertGreaterThan(animation.count, 1, "\(mood) is a still in an animated wrapper")
            XCTAssertEqual(animation.delays.count, animation.count)
            for index in 0..<animation.count {
                // Nothing on a desktop that is always on screen gets to run at
                // sixty frames a second.
                XCTAssertGreaterThanOrEqual(animation.delay(at: index), 0.05, "\(mood)")
            }
        }
    }

    func testMissingArtworkIsNilRatherThanACrash() {
        XCTAssertNil(CatArtwork.animation(named: "cat-there-is-no-such-mood"))
    }
}

/// Whether anybody is looking, which is a different question from whether they
/// have taken a break.
@MainActor
final class PresenceWatchingTests: XCTestCase {

    private func tracker(idle: Double) -> PresenceTracker {
        PresenceTracker(idleSeconds: { idle })
    }

    func testTypingCountsAsWatching() {
        let presence = tracker(idle: 3)
        presence.tick()
        XCTAssertTrue(presence.isAtDesk)
    }

    /// The threshold that stops the tail. Deliberately far below the six
    /// minutes that count as a break: a quiet minute and a half is not a break,
    /// but it is nobody watching.
    func testAQuietDeskStopsBeingWatched() {
        let presence = tracker(idle: PresenceTracker.stillWatchingSeconds + 1)
        presence.tick()
        XCTAssertFalse(presence.isAtDesk)
        XCTAssertGreaterThan(presence.sittingMinutes, 0,
                             "still sitting — a quiet minute is not a break")
    }

    func testComingBackResumesIt() {
        let idle = LockedValue(600.0)
        let presence = PresenceTracker(idleSeconds: { idle.value })
        presence.tick()
        XCTAssertFalse(presence.isAtDesk)
        idle.value = 1
        presence.tick()
        XCTAssertTrue(presence.isAtDesk)
    }
}

/// A box a test can change from outside the escaping closure.
private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
