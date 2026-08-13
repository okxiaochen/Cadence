import SwiftUI

/// The agenda behind the status item: everything scheduled, grouped into
/// Today, Tomorrow and Upcoming.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    @State private var newTask = ""

    private var now: Date { model.clock }
    private var sections: [AgendaSection] { model.agendaSections(now: now) }

    var body: some View {
        VStack(spacing: 0) {
            runningBar
            header
            Divider()

            if sections.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                                .padding(.bottom, 3)

                            ForEach(section.items) { item in
                                AgendaRow(item: item, now: now)
                            }
                        }
                    }
                    .padding(.bottom, 6)
                }
                // A fixed height, not a maximum: the popover window sizes
                // itself to its content, so a flexible child makes the two
                // measure each other in a loop.
                .frame(height: 320)
            }

            Divider()
            footer
        }
        .frame(width: 320)
    }

    // MARK: - Header

    /// Running timers outrank the agenda: they are the thing costing you
    /// something while the app is off screen.
    @ViewBuilder
    private var runningBar: some View {
        if !model.runningEntries.isEmpty {
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
