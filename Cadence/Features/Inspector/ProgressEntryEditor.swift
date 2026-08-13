import SwiftUI

/// Add or correct one timeline entry: when it happened, how long it took, and
/// what came of it.
///
/// The times are editable because a stopwatch is not how most work gets
/// remembered — you notice an hour later that you never started it, or you
/// leave one running through lunch. A tracked total nobody can correct is a
/// tracked total nobody trusts.
struct ProgressEntryEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// The entry being corrected, or `nil` when logging a new one.
    var entry: ProgressEntry?
    var taskID: String

    @State private var kind: ProgressKind
    @State private var day: Date
    @State private var start: Date
    @State private var end: Date
    @State private var note: String

    /// A session already running has no end to edit — only where it began.
    private var isRunning: Bool { entry?.isRunning ?? false }
    private var isNew: Bool { entry == nil }

    init(entry: ProgressEntry?, taskID: String) {
        self.entry = entry
        self.taskID = taskID

        let now = Date()
        let started = entry?.startedAt ?? now.addingTimeInterval(-30 * 60)
        _kind = State(initialValue: entry?.kind ?? .session)
        _day = State(initialValue: Calendar.current.startOfDay(for: started))
        _start = State(initialValue: started)
        _end = State(initialValue: entry?.endedAt ?? max(started, now))
        _note = State(initialValue: entry?.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "Log Time" : "Edit Entry")
                .font(.headline)

            if isNew {
                Picker("", selection: $kind) {
                    Text("Time spent").tag(ProgressKind.session)
                    Text("Just a note").tag(ProgressKind.note)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            LabeledContent("Day") {
                QuietDateField(date: $day)
            }

            if kind == .session {
                LabeledContent("From") {
                    QuietDateField(date: $start, timeOnly: true)
                }
                if !isRunning {
                    LabeledContent("To") {
                        HStack(spacing: 8) {
                            QuietDateField(date: $end, timeOnly: true)
                            Text(durationLabel)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(isValid ? .secondary : Color.red)
                        }
                    }
                } else {
                    Text("Still running — stop the timer to set an end.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("At") {
                    QuietDateField(date: $start, timeOnly: true)
                }
            }

            LabeledContent("Note") {
                TextField("What got done", text: $note)
                    .quietField(width: 190)
            }

            HStack {
                if let entry, !isRunning {
                    Button("Delete") {
                        model.deleteProgress(entry)
                        dismiss()
                    }
                    .buttonStyle(.quiet)
                    .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.quiet)
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save", action: save)
                    .buttonStyle(.quietProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    // MARK: - Values

    /// The pickers hold a day and a time of day separately, so the day can be
    /// changed without dragging the times along with it.
    private func combine(_ time: Date) -> Date {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.date(
            bySettingHour: parts.hour ?? 0,
            minute: parts.minute ?? 0,
            second: 0,
            of: day
        ) ?? time
    }

    private var resolvedStart: Date { combine(start) }

    /// An end before its start means the session ran past midnight, which is
    /// the reading that needs no error message.
    private var resolvedEnd: Date {
        let end = combine(self.end)
        guard end <= resolvedStart else { return end }
        return end.addingTimeInterval(86_400)
    }

    private var minutes: Int {
        max(0, Int(resolvedEnd.timeIntervalSince(resolvedStart) / 60))
    }

    private var durationLabel: String {
        minutes == 0 ? "0m" : Format.duration(minutes)
    }

    private var isValid: Bool {
        kind == .note || isRunning || minutes > 0
    }

    private func save() {
        guard isValid else { return }

        if var entry {
            entry.kind = kind
            entry.startedAt = resolvedStart
            entry.endedAt = isRunning ? nil : (kind == .session ? resolvedEnd : nil)
            entry.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            model.updateProgress(entry)
        } else if kind == .session {
            model.logSession(from: resolvedStart, to: resolvedEnd, note: note, for: taskID)
        } else {
            model.logProgress(note, at: resolvedStart, for: taskID)
        }
        dismiss()
    }
}
