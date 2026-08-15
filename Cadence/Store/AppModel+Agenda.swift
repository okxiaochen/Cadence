import Foundation
import GRDB

/// The menu bar's data. A window anchored on *today* rather than on whatever
/// the calendar view happens to be showing.
extension AppModel {

    /// Forward to the horizon, and backwards without limit.
    ///
    /// It used to start at today, which meant nothing from an earlier day was
    /// ever fetched — so the Overdue section could not fill, however the
    /// grouping was written. A bounded lookback would only move the problem:
    /// a task three months late is still late, and dropping it silently is the
    /// failure the section exists to prevent. The blocks query is told
    /// `openOnly` so the cost tracks outstanding work, not history.
    var agendaRange: DateInterval {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: AgendaBuilder.upcomingDays + 1, to: today)
            ?? today.addingTimeInterval(86_400)
        return DateInterval(start: .distantPast, end: end)
    }

    func restartAgendaObservation() {
        agendaAnchorDay = Calendar.current.startOfDay(for: Date())
        let range = agendaRange

        let observation = ValueObservation.tracking { db in
            AgendaSnapshot(
                blocks: try TodoRepository.scheduledBlocks(db, in: range, openOnly: true),
                allDay: try TodoRepository.allDay(db, in: range)
            )
        }
        agendaCancellable = observation.start(
            in: database.writer,
            onError: { [weak self] error in
                MainActor.assumeIsolated { self?.errorMessage = error.localizedDescription }
            },
            onChange: { [weak self] snapshot in
                MainActor.assumeIsolated {
                    self?.agendaItems = AgendaBuilder.items(
                        blocks: snapshot.blocks,
                        allDay: snapshot.allDay
                    )
                }
            }
        )
    }

    /// Rebuilds the window when the date rolls over, so "Today" does not go on
    /// meaning yesterday in an app that has been left running.
    func refreshAgendaIfDayChanged() {
        let today = Calendar.current.startOfDay(for: Date())
        guard today != agendaAnchorDay else { return }
        restartAgendaObservation()
    }

    func agendaSections(now: Date = Date()) -> [AgendaSection] {
        AgendaBuilder.sections(from: agendaItems, now: now)
    }

    /// Open work left for today, for the status item.
    ///
    /// `includingOverdue` follows the agenda's own Overdue section: with it
    /// collapsed the badge counts only what is still ahead today, so putting
    /// the section away actually puts the number away too.
    func todayRemainingCount(
        includingOverdue: Bool = true,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        let startOfTomorrow = calendar.date(
            byAdding: .day, value: 1, to: calendar.startOfDay(for: now)
        ) ?? now
        return agendaItems.filter { item in
            guard item.day < startOfTomorrow, !item.todo.isCompleted else { return false }
            return includingOverdue || !item.isOverdue(now, calendar: calendar)
        }.count
    }

    func todayCountLabel(includingOverdue: Bool = true) -> String {
        let count = todayRemainingCount(includingOverdue: includingOverdue)
        return count == 0 ? "" : "\(count)"
    }

    /// What the status item says. A running clock displaces the count: while
    /// something is being timed it is the only number worth the width, and the
    /// label stays as bounded as the count it replaces — minutes for the first
    /// hour, then `1h 05m`. Several at once show the longest, with how many
    /// others are going, because a menu bar has no room for a list.
    func menuBarLabel(includingOverdue: Bool = true) -> String {
        guard isTimingAnything else {
            return todayCountLabel(includingOverdue: includingOverdue)
        }
        let minutes = max(0, longestRunningSeconds / 60)
        let elapsed = minutes < 60
            ? "\(minutes)m"
            : String(format: "%dh %02dm", minutes / 60, minutes % 60)
        return runningEntries.count > 1 ? "\(elapsed) ×\(runningEntries.count)" : elapsed
    }

    /// Timing is a different state from "here is your day", so the icon says so
    /// rather than leaving the number to carry it alone.
    var menuBarSymbol: String {
        isTimingAnything ? "stopwatch.fill" : "calendar.day.timeline.left"
    }

    /// What the menu bar header reports about today.
    func agendaFocus(now: Date = Date()) -> AgendaBuilder.Focus {
        AgendaBuilder.focus(in: agendaItems, now: now)
    }
}

private struct AgendaSnapshot: Equatable {
    var blocks: [ScheduledBlock]
    var allDay: [TodoDetail]
}
