import AppKit
import Foundation
import Observation

/// How long somebody has actually been at the desk.
///
/// The app already knew how long a *timer* had been running, which is a
/// different question — most people sit for hours without starting one, and
/// starting one and walking away is common enough to be the reason
/// `truncateAbandoned` exists. "You have been sitting for fifty minutes" needs
/// to be about sitting.
///
/// The only signal macOS offers for it is how long since the last keystroke or
/// mouse move, which is a proxy and worth being honest about: reading at the
/// desk looks identical to having left. That asymmetry is why the away
/// threshold is generous — being told to stretch when you already have is the
/// annoying failure, and it is the one this errs against.
@MainActor
@Observable
final class PresenceTracker {

    /// Idle for this long and they are treated as having got up. Long enough to
    /// survive reading a page; short enough that a coffee counts as a break.
    static let awayAfterMinutes = 6

    /// Quiet for this long and the desk is treated as empty *for the purpose of
    /// drawing*. Much shorter than `awayAfterMinutes`, because the two answer
    /// different questions: whether somebody has taken a break, and whether
    /// anybody is looking. A cat wagging its tail at an empty chair costs
    /// battery on behalf of nobody.
    static let stillWatchingSeconds: Double = 90

    /// Unbroken minutes at the desk. Reset by an absence.
    private(set) var sittingMinutes = 0
    /// Whether anyone is plausibly looking at the screen right now.
    private(set) var isAtDesk = true
    /// Minutes present since the last glass of water was suggested and taken.
    private(set) var minutesSinceWater = 0
    private(set) var lastNudgedAt: Date?

    private var task: Task<Void, Never>?
    private let idleSeconds: @Sendable () -> Double

    /// Injected so the whole thing can be driven from a test without a mouse.
    init(idleSeconds: @escaping @Sendable () -> Double = PresenceTracker.systemIdleSeconds) {
        self.idleSeconds = idleSeconds
    }

    static let systemIdleSeconds: @Sendable () -> Double = {
        // Any input at all, not just one kind: someone typing without touching
        // the mouse is still at the desk.
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .init(rawValue: ~0)!
        )
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                tick()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// One minute of wall clock, folded in.
    func tick(now: Date = Date()) {
        let idle = idleSeconds()
        isAtDesk = idle < Self.stillWatchingSeconds

        if idle >= Double(Self.awayAfterMinutes) * 60 {
            // They got up. That is the break, so nothing needs suggesting and
            // the count starts again when they come back.
            sittingMinutes = 0
            lastNudgedAt = nil
        } else {
            sittingMinutes += 1
            minutesSinceWater += 1
        }
    }

    /// Called when a nudge is shown, so it is not shown again immediately.
    func noteNudged(at moment: Date = Date()) {
        lastNudgedAt = moment
    }

    /// Called when the water suggestion is acted on or dismissed.
    func noteWater() {
        minutesSinceWater = 0
        lastNudgedAt = Date()
    }
}

/// A small thing worth saying about the body rather than the work.
///
/// Separate from the plan and deliberately quieter than it: this interrupts
/// somebody who did not ask, so the bar is "would a colleague mention this"
/// rather than "is it true".
enum PetNudge: Equatable {
    case none
    case move(sittingMinutes: Int)
    case water(afterMinutes: Int)

    var isSomething: Bool { self != .none }

    var message: String? {
        switch self {
        case .none: nil
        case .move(let minutes):
            "\(Format.duration(minutes)) at the desk — worth standing up."
        case .water(let minutes):
            "\(Format.duration(minutes)) since the last one. Water?"
        }
    }

    /// Sitting outranks water: one of them is about getting up, and getting up
    /// is usually how the other gets solved anyway.
    static func decide(
        sittingMinutes: Int,
        minutesSinceWater: Int,
        moveAfter: Int,
        waterAfter: Int,
        lastNudgedAt: Date?,
        cooldown: TimeInterval = 20 * 60,
        now: Date = Date()
    ) -> PetNudge {
        if let lastNudgedAt, now.timeIntervalSince(lastNudgedAt) < cooldown { return .none }
        if moveAfter > 0, sittingMinutes >= moveAfter {
            return .move(sittingMinutes: sittingMinutes)
        }
        if waterAfter > 0, minutesSinceWater >= waterAfter {
            return .water(afterMinutes: minutesSinceWater)
        }
        return .none
    }
}
