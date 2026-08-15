import SwiftUI

/// The agenda behind the status item: everything scheduled, grouped into
/// Today, Tomorrow and Upcoming.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences
    @Environment(\.openWindow) private var openWindow

    @State private var newTask = ""

    /// Lives on `Preferences` rather than in an `@AppStorage` here: the status
    /// item's count reads it too, and it has to redraw the moment it changes.
    private var showsOverdue: Bool { preferences.showsOverdue }

    private var now: Date { model.clock }
    private var sections: [AgendaSection] { model.agendaSections(now: now) }

    var body: some View {
        VStack(spacing: 0) {
            runningBar
            header
            Divider()
            agenda
            Divider()
            footer
        }
        // One constant size for every state, never the content's own height.
        // The popover window grows to fit its content but does not shrink back,
        // so any variant shorter than the tallest one — no running timer, a
        // one-line header instead of "Up next" — left the leftover window
        // transparent and the desktop showed through above and below.
        //
        // Everything above and below the agenda therefore has to be fixed, and
        // the agenda absorbs the difference. `.frame` proposes a size rather
        // than enforcing one, so the clip is what actually holds the bound.
        .frame(width: 320, height: 420)
        .clipped()
    }

    private var agenda: some View {
        Group {
            if sections.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            sectionHeader(section)

                            if section.kind != .overdue || showsOverdue {
                                ForEach(section.items) { item in
                                    AgendaRow(
                                        item: item,
                                        now: now,
                                        daysLate: section.kind == .overdue
                                            ? item.daysLate(now) : 0
                                    )
                                }
                            }
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Overdue is the only section that collapses, and it keeps its count in
    /// the header when closed: a section you can hide has to go on saying how
    /// much is behind it, or hiding it is how the work gets forgotten.
    @ViewBuilder
    private func sectionHeader(_ section: AgendaSection) -> some View {
        if section.kind == .overdue {
            Button {
                preferences.showsOverdue.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(section.title)
                    Text("\(section.items.count)")
                        .monospacedDigit()
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.18), in: Capsule())
                    Spacer(minLength: 0)
                    Image(systemName: showsOverdue ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showsOverdue
                  ? "Hide overdue work, and stop counting it in the menu bar"
                  : "Show overdue work")
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 3)
        } else {
            Text(section.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 3)
        }
    }

    // MARK: - Header

    /// Running timers outrank the agenda: they are the thing costing you
    /// something while the app is off screen.
    @ViewBuilder
    private var runningBar: some View {
        if !model.runningEntries.isEmpty {
            // Scrolls past two timers rather than growing: the window is a
            // fixed height, so anything that grows here comes straight out of
            // the agenda below.
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.runningEntries) { entry in
                        runningRow(entry)
                    }
                    if model.runningEntries.count > 1 {
                        HStack {
                            Spacer()
                            Button("Stop All") { model.stopAllTimers() }
                                .buttonStyle(.quiet)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 108)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
        }
    }

    private func runningRow(_ entry: ProgressEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "stopwatch.fill").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.runningTodo(entry.taskID)?.title ?? "Timing")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("since \(Format.time(entry.startedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Format.duration(max(1, model.runningSeconds(for: entry.taskID) / 60)))
                .font(.callout.monospacedDigit().weight(.medium))
            Button("Stop") { model.stopTimer(for: entry.taskID) }
                .buttonStyle(.quiet)
        }
    }

    @ViewBuilder
    private var header: some View {
        Group {
            switch model.agendaFocus(now: now) {
            case .underway(let item):
                task(item, label: "Now")
            case .next(let item):
                task(item, label: "Up next")
            case .overdue(let count):
                summary(
                    count == 1 ? "1 task still open today"
                               : "\(count) tasks still open today",
                    symbol: "clock.badge.exclamationmark",
                    tint: .orange
                )
            case .allDone(let count):
                summary(
                    count == 1 ? "Today is done" : "All \(count) done today",
                    symbol: "checkmark.circle.fill",
                    tint: .green
                )
            case .empty:
                summary("Nothing scheduled today", symbol: "calendar", tint: .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func task(_ item: AgendaItem, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(item.todo.title)
                .font(.headline)
                .lineLimit(1)
            if let interval = item.interval {
                Text(remaining(for: interval))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout)
            Spacer()
        }
    }

    private func remaining(for interval: DateInterval) -> String {
        if interval.contains(now) {
            let left = Int(interval.end.timeIntervalSince(now) / 60)
            return "\(Format.time(interval.start))–\(Format.time(interval.end)) · "
                + "\(Format.duration(max(1, left))) left"
        }
        let until = Int(interval.start.timeIntervalSince(now) / 60)
        return "\(Format.time(interval.start)) · in \(Format.duration(max(1, until)))"
    }

    private var empty: some View {
        VStack(spacing: 4) {
            Image(systemName: "calendar")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("Nothing scheduled")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle").foregroundStyle(.secondary)
                TextField("Add a task", text: $newTask)
                    .textFieldStyle(.plain)
                    .onSubmit(add)
            }

            HStack {
                Button("Open Cadence") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                Button("Report") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "report")
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func add() {
        let parsed = CaptureParser.parse(newTask)
        guard !parsed.isEmpty else { return }
        model.createTodo(
            title: parsed.title,
            tagNames: parsed.tagNames,
            priority: parsed.priority,
            estimateMinutes: parsed.estimateMinutes,
            dueAt: parsed.dueAt,
            scheduledAt: parsed.scheduledAt
        )
        newTask = ""
    }
}

// MARK: - Row

private struct AgendaRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var item: AgendaItem
    var now: Date
    /// 0 unless this is listed under Overdue and belongs to an earlier day.
    var daysLate: Int = 0

    @State private var isHovering = false

    private var isTiming: Bool { model.isTiming(item.todo.id) }

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { item.todo.isCompleted },
                set: { _ in model.toggleCompleted(item.todo.id) }
            )) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 1) {
                Text(item.todo.title)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(item.hasPassed(now) ? .secondary : .primary)

                HStack(spacing: 5) {
                    // Leads the line: a carried-over block otherwise shows a
                    // bare "10:00–10:30" that reads exactly like today's.
                    if daysLate > 0 {
                        Text(daysLate == 1 ? "1 day late" : "\(daysLate) days late")
                            .fontWeight(.medium)
                            .foregroundStyle(.orange)
                    }
                    if let interval = item.interval {
                        Text("\(Format.time(interval.start))–\(Format.time(interval.end))")
                            .monospacedDigit()
                    } else {
                        Text("All day")
                    }
                    if let project = item.project {
                        Dot(colorHex: project.colorHex, size: 5)
                        Text(project.name).lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            // Timing from here, without opening the app — the menu bar is
            // where you are when you actually start work.
            if isTiming {
                Text(Format.duration(max(1, model.runningSeconds(for: item.todo.id) / 60)))
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.tint)
            } else if item.isUnderway(now) {
                Text("now")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.tint.opacity(0.2), in: Capsule())
            }

            if isTiming || isHovering {
                Button {
                    model.toggleTimer(for: item.todo.id)
                } label: {
                    Image(systemName: isTiming ? "stop.circle.fill" : "play.circle")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(isTiming ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .help(isTiming ? "Stop the timer" : "Start timing this task")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(isHovering ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            // Opening the detail is more useful than opening the window on a
            // list you are only glancing at.
            model.inspectedID = item.todo.id
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
