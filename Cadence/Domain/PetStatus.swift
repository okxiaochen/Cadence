import Foundation

/// What the desktop companion knows right now.
///
/// Pure, so what it decides to say can be tested without a window. Everything
/// here is derived from state the app already keeps — the agenda, the running
/// timer, the calendar — because a companion that knew things the rest of the
/// app did not would be a second source of truth about the same day.
struct PetStatus: Equatable {
    /// Open work due today or earlier, the same number the status item shows.
    var openToday: Int
    var focus: AgendaBuilder.Focus
    /// The next meeting, if one is close enough to be worth mentioning.
    var nextEvent: PetStatus.Event?
    /// A meeting that has just finished and not yet been answered.
    ///
    /// The moment worth catching: what a meeting produced is clearest in the
    /// thirty seconds after it, and gone by the time anyone opens a task list.
    var justEnded: PetStatus.Event?
    /// Minutes on the clock right now, if anything is being timed.
    var timingMinutes: Int?
    var breakAdvice: BreakAdvice

    /// Today, as one list.
    ///
    /// Tasks and calendar events interleaved rather than kept apart, because
    /// the question being asked is "what is my day", and a day does not come in
    /// two columns. Which one a line came from is a property of the line, not a
    /// reason to split the list.
    var today: [Line] = []

    struct Event: Equatable {
        var title: String
        var start: Date
        /// Whole minutes from now until it starts; negative once it has begun.
        var minutesAway: Int
    }

    struct Line: Identifiable, Equatable {
        enum Kind: Equatable { case task, event }

        var id: String
        var kind: Kind
        var title: String
        /// Nil for something with a day but no time.
        var at: Date?
        var isDone: Bool = false
        /// How late it is, in whole days. 0 for anything not overdue.
        var daysLate: Int = 0
        /// Sorting key: timed things in time order, all-day work first.
        var sortAt: Date
    }

    /// How the companion should look, which is the only thing it says without
    /// being asked.
    enum Mood: Equatable {
        case idle
        case working
        case restDue
        case behind
        case clear
    }

    var mood: Mood {
        if breakAdvice.isDue { return .restDue }
        if timingMinutes != nil { return .working }
        switch focus {
        case .overdue: return .behind
        case .allDone: return .clear
        case .underway, .next: return .idle
        case .empty: return openToday > 0 ? .behind : .clear
        }
    }
}

/// Whether it is time to stop, and whether saying so would be nagging.
///
/// A companion that mentions a break every minute past the threshold is one
/// people turn off in an afternoon, so the reminder has a cooldown and the
/// cooldown is part of the decision rather than something the view remembers.
enum BreakAdvice: Equatable {
    case none
    /// Long enough at it to be worth saying so.
    case due(workedMinutes: Int)

    var isDue: Bool { if case .due = self { return true }; return false }

    static func decide(
        timingSeconds: Int?,
        after threshold: Int,
        lastSuggestedAt: Date?,
        cooldown: TimeInterval = 15 * 60,
        now: Date = Date()
    ) -> BreakAdvice {
        // Nothing running means nothing to interrupt. A break you are already
        // taking does not need suggesting.
        guard let timingSeconds else { return .none }
        let minutes = timingSeconds / 60
        guard minutes >= threshold else { return .none }
        if let lastSuggestedAt, now.timeIntervalSince(lastSuggestedAt) < cooldown {
            return .none
        }
        return .due(workedMinutes: minutes)
    }
}

extension PetStatus {

    /// How far ahead a meeting is worth mentioning at all. Beyond this it is
    /// not "coming up", it is just something in the calendar.
    static let eventHorizonMinutes = 45

    /// How long after a meeting it is still worth asking what came out of it.
    /// Long enough to catch someone coming back to their desk, short enough
    /// that it is not asking about this morning.
    static let followUpWindowMinutes = 12

    /// One line, in the app's voice rather than a pet's. What it says has to be
    /// worth the interruption, so the order is: something is wrong, something
    /// is about to start, something is running, then the day in general.
    var headline: String {
        if case .due(let worked) = breakAdvice {
            return "\(Format.duration(worked)) without a break."
        }
        // Being late to the next thing matters more than tidying up the last
        // one, so this order is the other way round from how they were added.
        if let event = nextEvent {
            if event.minutesAway <= 0 { return "\(event.title) — now." }
            return "\(event.title) in \(Format.duration(event.minutesAway))."
        }
        if let ended = justEnded {
            return "\(ended.title) — anything to follow up?"
        }
        if let timingMinutes {
            return "Timing — \(Format.duration(max(1, timingMinutes)))."
        }
        switch focus {
        case .underway(let item): return "Now: \(item.todo.title)"
        case .next(let item): return "Next: \(item.todo.title)"
        case .overdue(let count):
            return count == 1 ? "1 task still open." : "\(count) tasks still open."
        case .allDone: return "Today is done."
        case .empty: return openToday > 0 ? "\(openToday) open." : "Nothing scheduled."
        }
    }
}
