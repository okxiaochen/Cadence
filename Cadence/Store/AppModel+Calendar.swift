import Foundation
import GRDB

/// Calendar reads and block mutations. Writes go through the same `mutate`
/// as everything else, so a drag is one undo step and an AI turn in M3 will be
/// indistinguishable from it at the storage layer.
extension AppModel {

    // MARK: - Visible range

    var visibleDays: [Date] {
        calendarScale.days(anchoredAt: calendarAnchor)
    }

    var visibleRange: DateInterval {
        let days = visibleDays
        let calendar = Calendar.current
        guard let first = days.first, let last = days.last,
              let end = calendar.date(byAdding: .day, value: 1, to: last)
        else {
            let start = calendar.startOfDay(for: calendarAnchor)
            return DateInterval(start: start, end: start.addingTimeInterval(86_400))
        }
        return DateInterval(start: first, end: end)
    }

    func restartCalendarObservation() {
        let range = visibleRange
        let observation = ValueObservation.tracking { db in
            CalendarSnapshot(
                blocks: try TodoRepository.scheduledBlocks(db, in: range),
                unscheduled: try TodoRepository.unscheduled(db),
                due: try TodoRepository.allDay(db, in: range)
            )
        }
        calendarCancellable = observation.start(
            in: database.writer,
            onError: { [weak self] error in
                MainActor.assumeIsolated { self?.errorMessage = error.localizedDescription }
            },
            onChange: { [weak self] snapshot in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scheduledBlocks = snapshot.blocks
                    self.unscheduled = snapshot.unscheduled
                    self.dueInRange = snapshot.due
                    if let selected = self.selectedBlockID,
                       !snapshot.blocks.contains(where: { $0.id == selected }) {
                        self.selectedBlockID = nil
                    }
                }
            }
        )
        refreshBusyEvents()
    }

    /// Publishes the sync window to Apple Calendar. Cheap and idempotent when
    /// nothing changed, so it is safe to call after every mutation.
    func publishToCalendar() {
        guard calendarSync.isEnabled else { return }
        let report = calendarSync.reconcile()
        eventKit.managedCalendarID = calendarSync.managedCalendarID
        if let error = calendarSync.lastError { errorMessage = error }
        if !report.isEmpty { refreshBusyEvents() }
    }

    func refreshBusyEvents() {
        eventKit.load(range: visibleRange, hiddenCalendarIDs: Preferences.shared.hiddenCalendarIDs)
    }

    // MARK: - Navigation

    func goToToday() {
        calendarAnchor = Date()
    }

    func stepCalendar(by direction: Int) {
        let days = calendarScale.strideDays * direction
        if let next = Calendar.current.date(byAdding: .day, value: days, to: calendarAnchor) {
            calendarAnchor = next
        }
    }

    var positionedBlocks: [PositionedBlock] {
        CalendarLayout.position(scheduledBlocks, days: visibleDays)
    }

    /// All-day events, grouped by the day column they belong to.
    func allDayEvents(on day: Date) -> [BusyEvent] {
        let calendar = Calendar.current
        return eventKit.events.filter {
            $0.isAllDay && calendar.isDate($0.start, inSameDayAs: day)
        }
    }

    /// Tasks that land on `day` with no time of day — the all-day lane.
    func dueTasks(on day: Date) -> [TodoDetail] {
        let calendar = Calendar.current
        return dueInRange.filter { detail in
            guard let dueAt = detail.todo.dueAt else { return false }
            return calendar.isDate(dueAt, inSameDayAs: day)
        }
    }

    func busyEvents(on day: Date) -> [BusyEvent] {
        let calendar = Calendar.current
        return eventKit.events.filter {
            !$0.isAllDay && calendar.isDate($0.start, inSameDayAs: day)
        }
    }

    // MARK: - Block mutations

    /// Drops a task onto the grid. Duration comes from the estimate, falling
    /// back to the default; the caller has already snapped `start`.
    @discardableResult
    func schedule(todoID: String, at start: Date, duration: Int? = nil) -> String? {
        let blockID = UUID().uuidString
        let fallbackMinutes = Preferences.shared.defaultEstimateMinutes
        var created = false

        mutate("Schedule Task", affecting: [todoID]) { db in
            // The estimate is read inside the transaction, not from the
            // in-memory list — the observation may not have delivered this task
            // yet, and the AI in M3 will schedule tasks that are not on screen.
            guard var todo = try TodoRepository.fetch(db, id: todoID) else { return }
            let minutes = max(5, duration ?? todo.estimateMinutes ?? fallbackMinutes)

            // A task dropped onto the calendar is no longer untriaged.
            if todo.status == .inbox {
                todo.status = .todo
                try TodoRepository.update(db, todo)
            }
            try TodoRepository.insertBlock(db, TimeBlock(
                id: blockID,
                taskID: todoID,
                startAt: start,
                endAt: start.addingTimeInterval(TimeInterval(minutes * 60))
            ))
            created = true
        }

        guard created else { return nil }
        selectedBlockID = blockID
        return blockID
    }

    /// Move or resize. `interval` is already snapped and validated by the view.
    func setBlockInterval(_ blockID: String, to interval: DateInterval, actionName: String = "Move Block") {
        guard let taskID = taskID(forBlock: blockID) else { return }
        mutate(actionName, affecting: [taskID]) { db in
            guard var block = try TodoRepository.fetchBlock(db, id: blockID) else { return }
            block.startAt = interval.start
            block.endAt = interval.end
            try TodoRepository.updateBlock(db, block)
        }
    }

    /// Sets a block's length from its start, clamped so it stays inside the day.
    func setBlockDuration(_ blockID: String, minutes: Int) {
        guard let existing = block(withID: blockID) else { return }
        let endOfDay = Calendar.current.startOfDay(for: existing.startAt).addingTimeInterval(86_400)
        let end = min(
            existing.startAt.addingTimeInterval(TimeInterval(max(5, minutes) * 60)),
            endOfDay
        )
        setBlockInterval(
            blockID,
            to: DateInterval(start: existing.startAt, end: end),
            actionName: "Change Duration"
        )
    }

    /// Copies the block's length onto the task's estimate — the usual follow-up
    /// after discovering by dragging how long something really needs.
    func adoptBlockDurationAsEstimate(_ blockID: String) {
        guard let existing = block(withID: blockID) else { return }
        mutate("Set Estimate", affecting: [existing.taskID]) { db in
            guard var todo = try TodoRepository.fetch(db, id: existing.taskID) else { return }
            todo.estimateMinutes = existing.durationMinutes
            try TodoRepository.update(db, todo)
        }
    }

    func deleteBlock(_ blockID: String) {
        guard let taskID = taskID(forBlock: blockID) else { return }
        mutate("Unschedule Task", affecting: [taskID]) { db in
            try TodoRepository.deleteBlock(db, id: blockID)
        }
        if selectedBlockID == blockID { selectedBlockID = nil }
    }

    /// Prefers the in-memory copy, but falls back to the database — the
    /// observation may not have delivered yet when a block is created and
    /// immediately acted on.
    private func block(withID blockID: String) -> TimeBlock? {
        if let known = scheduledBlocks.first(where: { $0.id == blockID }) {
            return known.block
        }
        return try? database.writer.read { db in
            try TodoRepository.fetchBlock(db, id: blockID)
        }
    }

    private func taskID(forBlock blockID: String) -> String? {
        block(withID: blockID)?.taskID
    }

    // MARK: - Conflicts

    /// Busy intervals a dragged block should avoid: real calendar events plus
    /// every other task block. Used to warn, never to block the drop — you are
    /// allowed to double-book yourself deliberately.
    func conflictIntervals(excluding blockID: String?) -> [DateInterval] {
        let others = scheduledBlocks
            .filter { $0.id != blockID && !$0.block.isAllDay }
            .map(\.interval)
        return FreeBusy.merge(others + eventKit.busyIntervals)
    }
}

private struct CalendarSnapshot: Equatable {
    var blocks: [ScheduledBlock]
    var unscheduled: [TodoDetail]
    var due: [TodoDetail]
}
