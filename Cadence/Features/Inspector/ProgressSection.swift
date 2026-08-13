import SwiftUI

/// What has actually happened on this task: time spent, and where the work got
/// to, newest first.
///
/// One timeline rather than two lists. A timed session and a line of "blocked
/// on the API" are the same question asked twice — *what happened, and when* —
/// and interleaving them is what makes a task you left a week ago readable.
struct ProgressSection: View {
    @Environment(AppModel.self) private var model

    var detail: TodoDetail

    @State private var draftNote = ""
    /// The entry whose editor is open. `.some(nil)` means a new one.
    @State private var editing: EditorTarget?

    /// The live timeline for the open panel; the detail's own copy is only a
    /// snapshot from whenever it was fetched.
    private var entries: [ProgressEntry] {
        model.inspectedID == detail.id ? model.inspectedEntries : detail.progressEntries
    }
    private var isTiming: Bool { model.isTiming(detail.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            controls
            noteField
            if entries.isEmpty {
                Text("Nothing recorded yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiaryText)
            } else {
                timeline
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Progress").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if totalMinutes > 0 {
                Text(summaryLine)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Tracked against estimated, when there is an estimate to compare with —
    /// the number that tells you whether the plan was ever realistic.
    private var summaryLine: String {
        let tracked = Format.duration(totalMinutes)
        guard let estimate = detail.todo.estimateMinutes, estimate > 0 else {
            return "\(tracked) tracked"
        }
        return "\(tracked) of \(Format.duration(estimate))"
    }

    private var totalMinutes: Int { detail.progress.trackedMinutes(now: model.clock) }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                model.toggleTimer(for: detail.id)
            } label: {
                Label(
                    isTiming
                        ? "Stop \(Format.duration(max(1, model.runningSeconds(for: detail.id) / 60)))"
                        : "Start Timer",
                    systemImage: isTiming ? "stop.fill" : "play.fill"
                )
                .monospacedDigit()
            }
            .buttonStyle(.quietProminent)

            Button("Log Time…") { editing = EditorTarget(entry: nil) }
                .buttonStyle(.quiet)
                .help("Record time you already spent, on any day")

            Spacer()
        }
        .popover(item: $editing) { target in
            ProgressEntryEditor(entry: target.entry, taskID: detail.id)
                .environment(model)
        }
    }

    // MARK: - Note field

    private var noteField: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.append").font(.caption).foregroundStyle(.secondary)
            TextField(
                isTiming ? "What did you get done? (saved when you stop)" : "Log progress…",
                text: $draftNote
            )
            .textFieldStyle(.plain)
            .onSubmit(commitNote)
        }
    }

    /// While the clock is running, a line typed here belongs to *this* session
    /// — so it stops the timer and attaches itself, rather than becoming a
    /// separate entry sitting next to one that says the same thing.
    private func commitNote() {
        let text = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if isTiming {
            model.stopTimer(for: detail.id, note: text)
        } else {
            model.logProgress(text, for: detail.id)
        }
        draftNote = ""
    }

    // MARK: - Timeline

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                ProgressRow(entry: entry, now: model.clock)
                    .contentShape(Rectangle())
                    // Correcting a mistimed entry is the common case, so it is
                    // a click on the entry rather than a menu item.
                    .onTapGesture { editing = EditorTarget(entry: entry) }
                    .contextMenu {
                        Button("Edit…") { editing = EditorTarget(entry: entry) }
                        if entry.isRunning {
                            Button("Stop Timer") { model.stopTimer(for: detail.id) }
                        }
                        Button("Delete", role: .destructive) { model.deleteProgress(entry) }
                    }
            }
        }
    }

    /// Identifiable so one `popover(item:)` serves every row — a per-row
    /// popover would mean a `@State` flag per row, which a `ForEach` cannot have.
    struct EditorTarget: Identifiable {
        var entry: ProgressEntry?
        var id: String { entry?.id ?? "new" }
    }
}

/// One entry: when it happened, how long it took, and what came of it.
private struct ProgressRow: View {
    var entry: ProgressEntry
    var now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(entry.isRunning ? AnyShapeStyle(Color.accentColor)
                                                 : AnyShapeStyle(.tertiaryText))
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(Format.date(entry.startedAt))
                        .font(.caption.weight(.medium))
                    if entry.kind == .session {
                        Text(rangeLine)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondaryText)
                    }
                    Spacer(minLength: 0)
                    if entry.kind == .session {
                        Text(Format.duration(max(1, entry.minutes(now: now))))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(entry.isRunning ? AnyShapeStyle(Color.accentColor)
                                                             : AnyShapeStyle(.secondaryText))
                    }
                }
                if !entry.note.isEmpty {
                    Text(entry.note)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var symbol: String {
        switch entry.kind {
        case .session: entry.isRunning ? "stopwatch.fill" : "stopwatch"
        case .note: "circle.fill"
        }
    }

    private var rangeLine: String {
        let start = Format.time(entry.startedAt)
        guard entry.kind == .session else { return start }
        return entry.isRunning
            ? "\(start) – now"
            : "\(start)–\(Format.time(entry.endedAt ?? entry.startedAt))"
    }
}
