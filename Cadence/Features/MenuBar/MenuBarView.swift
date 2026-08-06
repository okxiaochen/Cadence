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

    @ViewBuilder
    private var header: some View {
        if let focus = model.agendaFocus(now: now), let interval = focus.interval {
            VStack(alignment: .leading, spacing: 2) {
                Text(focus.isUnderway(now) ? "Now" : "Up next")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(focus.todo.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(remaining(for: interval))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        } else {
            HStack {
                Text("Nothing scheduled today")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
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

            if item.isUnderway(now) {
                Text("now")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.tint.opacity(0.2), in: Capsule())
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
