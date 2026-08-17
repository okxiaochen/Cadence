import Foundation

/// What the desktop companion reads.
///
/// Assembled here rather than in the view so the companion cannot drift from
/// the rest of the app: it is the same agenda, the same running timer and the
/// same calendar the window and the status item already use.
extension AppModel {

    func petStatus(now: Date = Date(), breakAfterMinutes: Int = 50) -> PetStatus {
        PetStatus(
            openToday: todayRemainingCount(now: now),
            focus: agendaFocus(now: now),
            nextEvent: nextEvent(now: now),
            justEnded: recentlyEndedEvent(now: now),
            timingMinutes: isTimingAnything ? longestRunningSeconds / 60 : nil,
            breakAdvice: BreakAdvice.decide(
                timingSeconds: isTimingAnything ? longestRunningSeconds : nil,
                after: breakAfterMinutes,
                lastSuggestedAt: lastBreakSuggestedAt,
                now: now
            ),
            today: todayLines(now: now)
        )
    }

    /// The day as one list: what is scheduled, what is due, and what is in the
    /// calendar, in the order it happens.
    func todayLines(now: Date = Date(), limit: Int = 12) -> [PetStatus.Line] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now

        // Anything from before today is still today's problem — the same rule
        // the agenda's Overdue section applies.
        let tasks = agendaItems
            .filter { $0.day < startOfTomorrow && !$0.todo.isCompleted }
            .map { item in
                PetStatus.Line(
                    id: item.id,
                    kind: .task,
                    title: item.todo.title,
                    at: item.interval?.start,
                    isDone: item.todo.isCompleted,
                    daysLate: item.daysLate(now, calendar: calendar),
                    // Untimed work leads the day rather than landing at midnight.
                    sortAt: item.interval?.start ?? startOfToday
                )
            }

        // All-day events are left out: "Conference — all day" is not a thing
        // happening at a moment, and it would sit at the top of every list.
        let events = eventKit.events
            .filter { !$0.isAllDay && $0.end > now && $0.start < startOfTomorrow }
            .map { event in
                PetStatus.Line(
                    id: "event-\(event.id)",
                    kind: .event,
                    title: event.title,
                    at: event.start,
                    sortAt: event.start
                )
            }

        return Array((tasks + events).sorted { left, right in
            if left.sortAt != right.sortAt { return left.sortAt < right.sortAt }
            // An event and a task at the same minute: the event is the one you
            // cannot move.
            if left.kind != right.kind { return left.kind == .event }
            return left.title < right.title
        }.prefix(limit))
    }

    /// The next meeting worth mentioning: one that has started and not finished,
    /// or one starting inside the horizon.
    ///
    /// All-day events are excluded. "Conference — all day" is not something you
    /// are about to be late for, and it would sit there saying so for a week.
    func nextEvent(now: Date = Date()) -> PetStatus.Event? {
        let horizon = now.addingTimeInterval(Double(PetStatus.eventHorizonMinutes) * 60)
        let candidate = eventKit.events
            .filter { !$0.isAllDay && $0.end > now && $0.start <= horizon }
            .min { $0.start < $1.start }
        guard let candidate else { return nil }
        return PetStatus.Event(
            title: candidate.title,
            start: candidate.start,
            minutesAway: Int(candidate.start.timeIntervalSince(now) / 60)
        )
    }

    /// A meeting that finished in the last few minutes and has not been
    /// answered yet.
    ///
    /// Something starting shortly outranks it: being late to the next thing
    /// matters more than tidying up the last one.
    func recentlyEndedEvent(now: Date = Date()) -> PetStatus.Event? {
        if let next = nextEvent(now: now), next.minutesAway <= 10 { return nil }
        let window = Double(PetStatus.followUpWindowMinutes) * 60
        let candidate = eventKit.events
            .filter { event in
                guard !event.isAllDay, event.end <= now else { return false }
                guard now.timeIntervalSince(event.end) <= window else { return false }
                return !answeredEventIDs.contains(event.id)
            }
            .max { $0.end < $1.end }
        guard let candidate else { return nil }
        return PetStatus.Event(
            title: candidate.title,
            start: candidate.start,
            minutesAway: Int(candidate.start.timeIntervalSince(now) / 60)
        )
    }

    /// Stops it asking again about a meeting already dealt with. Called when
    /// the panel is opened, which is the moment the question was read — whether
    /// or not anything was typed in reply.
    func noteEventAnswered(now: Date = Date()) {
        let window = Double(PetStatus.followUpWindowMinutes) * 60
        for event in eventKit.events
        where !event.isAllDay && event.end <= now && now.timeIntervalSince(event.end) <= window {
            answeredEventIDs.insert(event.id)
        }
    }

    /// Records that the break was mentioned, which starts the cooldown. Called
    /// when it is shown rather than when it is dismissed: the interruption has
    /// already happened by then.
    func noteBreakSuggested(at moment: Date = Date()) {
        lastBreakSuggestedAt = moment
    }
}
