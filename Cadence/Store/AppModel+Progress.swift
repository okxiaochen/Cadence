import Foundation
import GRDB

/// The timer, and the timeline it writes to.
///
/// Every write goes through the same `mutate` as everything else, so starting a
/// timer, stopping it, or logging a line is one undo step — and `TodoSnapshot`
/// carries the entries, so undo restores them exactly.
extension AppModel {

    // MARK: - Observation

    /// Watches every running session, app-wide. Kept separate from the list
    /// observation because the menu bar and the calendar need them whatever
    /// list happens to be on screen.
    func restartRunningObservation() {
        let observation = ValueObservation.tracking { db in
            try ProgressRepository.running(db)
        }
        runningCancellable = observation.start(
            in: database.writer,
            onError: { [weak self] error in
                MainActor.assumeIsolated { self?.errorMessage = error.localizedDescription }
            },
            onChange: { [weak self] entries in
                MainActor.assumeIsolated { self?.runningEntries = entries }
            }
        )
    }

    /// Follows `inspectedID`: the open panel's timeline, kept live.
    func restartInspectedProgressObservation() {
        guard let taskID = inspectedID else {
            inspectedProgressCancellable = nil
            inspectedEntries = []
            return
        }
        let observation = ValueObservation.tracking { db in
            try ProgressRepository.entries(db, taskID: taskID)
        }
        inspectedProgressCancellable = observation.start(
            in: database.writer,
            onError: { [weak self] error in
                MainActor.assumeIsolated { self?.errorMessage = error.localizedDescription }
            },
            onChange: { [weak self] entries in
                MainActor.assumeIsolated { self?.inspectedEntries = entries }
            }
        )
    }

    /// The title of a task being timed, wherever it happens to live.
    func runningTodo(_ taskID: String) -> Todo? {
        if let row = rows.first(where: { $0.id == taskID })?.todo { return row }
        if let child = rows.flatMap(\.children).first(where: { $0.id == taskID })?.todo { return child }
        return try? database.writer.read { db in try TodoRepository.fetch(db, id: taskID) }
    }

    /// Seconds on a task's clock, recomputed from `clock` so every view showing
    /// it ticks together and none of them owns a timer.
    func runningSeconds(for taskID: String) -> Int {
        guard let entry = runningEntries.first(where: { $0.taskID == taskID }) else { return 0 }
        return seconds(since: entry.startedAt)
    }

    /// The longest-running clock — what the status item reports when several
    /// are going at once.
    var longestRunningSeconds: Int {
        runningEntries.map { seconds(since: $0.startedAt) }.max() ?? 0
    }

    private func seconds(since start: Date) -> Int {
        max(0, Int(max(clock, Date()).timeIntervalSince(start)))
    }

    func isTiming(_ taskID: String) -> Bool {
        runningEntries.contains { $0.taskID == taskID }
    }

    var isTimingAnything: Bool { !runningEntries.isEmpty }

    // MARK: - Timer

    func startTimer(for taskID: String) {
        let exclusive = !Preferences.shared.allowsConcurrentTimers
        // Under one-at-a-time the tasks being stopped are affected too, so they
        // belong in the same undo step.
        let affected = exclusive
            ? [taskID] + runningEntries.map(\.taskID)
            : [taskID]
        mutate("Start Timer", affecting: affected) { db in
            try ProgressRepository.startSession(db, taskID: taskID, stoppingOthers: exclusive)
        }
    }

    /// Stops one task's session, optionally recording what got done in it.
    func stopTimer(for taskID: String, note: String = "") {
        guard isTiming(taskID) else { return }
        mutate("Stop Timer", affecting: [taskID]) { db in
            try ProgressRepository.stopSession(db, taskID: taskID, note: note)
        }
    }

    /// Stops everything still running.
    func stopAllTimers() {
        let affected = runningEntries.map(\.taskID)
        guard !affected.isEmpty else { return }
        mutate("Stop Timers", affecting: affected) { db in
            try ProgressRepository.stopAll(db)
        }
    }

    func toggleTimer(for taskID: String) {
        if isTiming(taskID) { stopTimer(for: taskID) } else { startTimer(for: taskID) }
    }

    // MARK: - Timeline

    func logProgress(_ text: String, at date: Date = Date(), for taskID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate("Log Progress", affecting: [taskID]) { db in
            try ProgressRepository.addNote(db, taskID: taskID, text: trimmed, at: date)
        }
    }

    /// Records time already spent, for the session you forgot to start.
    func logSession(from start: Date, to end: Date, note: String = "", for taskID: String) {
        guard end > start else { return }
        mutate("Log Time", affecting: [taskID]) { db in
            try ProgressRepository.addSession(db, taskID: taskID, from: start, to: end, note: note)
        }
    }

    /// The same, counted back from now — what "I've been at this 40 minutes"
    /// means without opening a date picker.
    func logSession(minutes: Int, for taskID: String, note: String = "") {
        guard minutes > 0 else { return }
        let end = Date()
        logSession(
            from: end.addingTimeInterval(TimeInterval(-minutes * 60)),
            to: end,
            note: note,
            for: taskID
        )
    }

    func updateProgress(_ entry: ProgressEntry) {
        mutate("Edit Progress", affecting: [entry.taskID]) { db in
            try ProgressRepository.update(db, entry)
        }
    }

    func deleteProgress(_ entry: ProgressEntry) {
        mutate("Delete Progress", affecting: [entry.taskID]) { db in
            try ProgressRepository.delete(db, id: entry.id)
        }
    }
}
