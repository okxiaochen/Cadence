import AppKit
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

    /// Watches for the two ways a timer records time nobody worked: the Mac
    /// sleeping with one running, and the plain forgotten one.
    ///
    /// The sleep notification arrives *before* the machine sleeps, so the time
    /// it carries is the last moment anyone was at the keyboard — which is
    /// exactly where the session should stop. It is recorded rather than acted
    /// on immediately, because the work happens on waking.
    func startAbandonedTimerWatch() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.wentToSleepAt = Date() }
        }
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.truncateAbandonedTimers() }
        }
        truncateAbandonedTimers()
    }

    /// Also called from the minute tick, so a timer left running while the Mac
    /// stays awake is still capped.
    func truncateAbandonedTimers() {
        guard !runningEntries.isEmpty else { return }
        let asleepSince = wentToSleepAt
        var affected: [String] = []
        do {
            try database.writer.write { db in
                affected = try ProgressRepository.truncateAbandoned(db, asleepSince: asleepSince)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        wentToSleepAt = nil
        // Not undoable on purpose: this is a correction to time that was never
        // worked, and the entry it writes is editable like any other.
        if !affected.isEmpty { scheduleCalendarPublish() }
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

    /// What ⌥⇧Space does, with no task in hand.
    ///
    /// Stopping is unambiguous, so anything running stops. Starting has to
    /// guess, and it guesses in the order the answer is most likely to be
    /// right: what you have selected, then what the agenda says you are in the
    /// middle of, then what is next today. If none of those exist there is
    /// nothing sensible to start, and it does nothing rather than picking a
    /// task at random.
    func toggleTimerForFocusedTask() {
        if isTimingAnything {
            stopAllTimers()
            return
        }
        if let selected = selection.first {
            startTimer(for: selected)
            return
        }
        switch agendaFocus() {
        case .underway(let item), .next(let item):
            startTimer(for: item.todo.id)
        case .overdue, .allDone, .empty:
            break
        }
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

    /// How long finished tasks like this one actually took. Read on demand
    /// rather than observed: it only changes when a task is completed, and the
    /// inspector is the only thing that asks.
    func calibration(for todo: Todo) -> EstimateCalibration? {
        try? database.writer.read { db in
            try ProgressRepository.calibration(db, for: todo)
        }
    }

    /// Everything recorded in a range, for the report.
    func timeReport(in range: DateInterval) -> TimeReport {
        (try? database.writer.read { db in
            try ProgressRepository.report(db, in: range)
        }) ?? TimeReport(range: range, lines: [])
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
