import Foundation
import GRDB

/// The menu bar's data. A window anchored on *today* rather than on whatever
/// the calendar view happens to be showing.
extension AppModel {

    var agendaRange: DateInterval {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: AgendaBuilder.upcomingDays + 1, to: start)
            ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    func restartAgendaObservation() {
        agendaAnchorDay = Calendar.current.startOfDay(for: Date())
        let range = agendaRange

        let observation = ValueObservation.tracking { db in
            AgendaSnapshot(
                blocks: try TodoRepository.scheduledBlocks(db, in: range),
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
    var todayRemainingCount: Int {
        let calendar = Calendar.current
        let startOfTomorrow = calendar.date(
            byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())
        ) ?? Date()
        return agendaItems.filter { $0.day < startOfTomorrow && !$0.todo.isCompleted }.count
    }

    var todayCountLabel: String {
        let count = todayRemainingCount
        return count == 0 ? "" : "\(count)"
    }

    /// What the status item says. A running clock displaces the count: while
    /// something is being timed it is the only number worth the width, and the
    /// label stays as bounded as the count it replaces — minutes for the first
    /// hour, then `1h 05m`. Several at once show the longest, with how many
    /// others are going, because a menu bar has no room for a list.
    var menuBarLabel: String {
        guard isTimingAnything else { return todayCountLabel }
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
