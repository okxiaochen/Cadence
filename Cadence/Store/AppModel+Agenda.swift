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

    /// What the status item shows: whatever is running, else the next thing today.
    func agendaFocus(now: Date = Date()) -> AgendaItem? {
        AgendaBuilder.focus(in: agendaItems, now: now)
    }
}

private struct AgendaSnapshot: Equatable {
    var blocks: [ScheduledBlock]
    var allDay: [TodoDetail]
}
