import SwiftUI

// MARK: - Single task

struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(AgentSession.self) private var session

    var detail: TodoDetail

    @State private var draft: Todo
    @State private var notesPreview = false
    @State private var newSubtask = ""

    init(detail: TodoDetail) {
        self.detail = detail
        _draft = State(initialValue: detail.todo)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                titleField
                aiActions
                Divider()
                attributes
                Divider()
                notesSection
                Divider()
                subtasksSection
                if !detail.blocks.isEmpty {
                    Divider()
                    blocksSection
                }
            }
            .padding(16)
        }
        .onChange(of: detail.todo) { _, newValue in
            // Adopt outside edits (undo, AI, another view) without clobbering
            // whatever is being typed here.
            if newValue != draft { draft = newValue }
        }
    }

    /// Canned prompts into the same agent loop as chat — one click, no typing.
    private var aiActions: some View {
        HStack(spacing: 6) {
            Button("Break Down") {
                session.send(
                    "Break down the task with id \(draft.id) into subtasks. "
                        + "Call get_task first to read its notes.",
                    surface: .breakdown
                )
            }
            Button("Estimate") {
                session.send(
                    "Estimate the task with id \(draft.id).",
                    surface: .estimate
                )
            }
            Button("Find a Slot") {
                session.send(
                    "Schedule the task with id \(draft.id) at the best available "
                        + "time before its due date.",
                    surface: .schedule
                )
            }
            Spacer()
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .disabled(session.status.isRunning || session.configurationProblem != nil)
    }

    private var titleField: some View {
        TextField("Title", text: $draft.title, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.title3.weight(.medium))
            .onSubmit(commit)
            .onChange(of: draft.title) { _, _ in }
    }

    private var attributes: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Status") {
                Picker("", selection: $draft.status) {
                    ForEach(TodoStatus.selectable, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .onChange(of: draft.status) { _, newValue in
                    model.setStatus(newValue, for: [draft.id])
                }
            }

            LabeledContent("Project") {
                Picker("", selection: Binding(
                    get: { draft.projectID ?? "" },
                    set: { newValue in
                        let id = newValue.isEmpty ? nil : newValue
                        draft.projectID = id
                        model.setProject(id, for: [draft.id])
                    }
                )) {
                    Text("None").tag("")
                    ForEach(model.projects) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
            }

            LabeledContent("Priority") {
                Picker("", selection: $draft.priority) {
                    ForEach(Priority.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .onChange(of: draft.priority) { _, newValue in
                    model.setPriority(newValue, for: [draft.id])
                }
            }

            LabeledContent("Estimate") {
                EstimateField(minutes: $draft.estimateMinutes, onCommit: commit)
            }

            WhenRow(
                date: detail.todo.dueAt,
                hasTime: !detail.blocks.isEmpty
            ) { date, includesTime in
                model.setWhen(date, includesTime: includesTime, for: [draft.id])
            }

            OptionalDateRow(title: "Defer Until", date: $draft.deferAt, onCommit: commit)

            tagsRow
            budgetLine
        }
    }

    private var tagsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags").font(.caption).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(model.tags) { tag in
                    let isOn = detail.tags.contains(tag)
                    Button {
                        model.toggleTag(tag.id, for: [draft.id])
                    } label: {
                        Text(tag.name)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(
                                Color(hex: tag.colorHex).opacity(isOn ? 0.25 : 0.08),
                                in: Capsule()
                            )
                            .foregroundStyle(isOn ? Color(hex: tag.colorHex) : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var budgetLine: some View {
        if let estimate = draft.estimateMinutes {
            let scheduled = detail.scheduledMinutes
            let short = max(0, estimate - scheduled)
            Text("\(Format.duration(estimate)) estimated · \(Format.duration(scheduled)) blocked"
                 + (short > 0 ? " · \(Format.duration(short)) short" : ""))
                .font(.caption)
                .foregroundStyle(short > 0 ? Color.orange : .secondary)
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Notes").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(notesPreview ? "Edit" : "Preview") { notesPreview.toggle() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            if notesPreview {
                Text(markdown(draft.notes))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                TextEditor(text: $draft.notes)
                    .font(.body)
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: draft.notes) { _, _ in commitDebounced() }
            }
        }
    }

    private var subtasksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Subtasks").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !detail.children.isEmpty {
                    Text("\(detail.completedChildCount)/\(detail.children.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(detail.children) { child in
                HStack(spacing: 6) {
                    Toggle(isOn: Binding(
                        get: { child.todo.isCompleted },
                        set: { _ in model.toggleCompleted(child.id) }
                    )) { EmptyView() }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    Text(child.todo.title)
                        .strikethrough(child.todo.isCompleted)
                        .foregroundStyle(child.todo.isCompleted ? .secondary : .primary)
                    Spacer()
                    Button {
                        model.delete(ids: [child.id])
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "plus").font(.caption).foregroundStyle(.secondary)
                TextField("Add subtask", text: $newSubtask)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        let title = newSubtask.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !title.isEmpty else { return }
                        model.addSubtask(to: draft.id, title: title)
                        newSubtask = ""
                    }
            }
        }
    }

    private var blocksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scheduled").font(.caption).foregroundStyle(.secondary)
            ForEach(detail.blocks) { block in
                HStack {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                    Text("\(Format.date(block.startAt)) · \(Format.time(block.startAt))–\(Format.time(block.endAt))")
                        .font(.callout)
                    Spacer()
                    Text(Format.duration(block.durationMinutes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Commit

    private func commit() {
        guard draft != detail.todo else { return }
        model.update(draft)
    }

    /// Notes change on every keystroke; only write once the value settles.
    private func commitDebounced() {
        let snapshot = draft
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if draft == snapshot { commit() }
        }
    }

    private func markdown(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
    }
}

// MARK: - Field helpers

private struct EstimateField: View {
    @Binding var minutes: Int?
    var onCommit: () -> Void

    @State private var text = ""

    var body: some View {
        TextField("e.g. 45m, 2h", text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 110)
            .onAppear { text = minutes.map(Format.duration) ?? "" }
            .onChange(of: minutes) { _, newValue in
                text = newValue.map(Format.duration) ?? ""
            }
            .onSubmit {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                minutes = trimmed.isEmpty ? nil : CaptureParser.minutes(from: trimmed)
                text = minutes.map(Format.duration) ?? ""
                onCommit()
            }
    }
}

/// The single date a task has. Adding a time turns it into a block on the
/// calendar; removing the time makes it an all-day item. There is no separate
/// "due" and "scheduled" — they are the same value.
private struct WhenRow: View {
    var date: Date?
    var hasTime: Bool
    var onChange: (Date?, Bool) -> Void

    var body: some View {
        LabeledContent("When") {
            HStack(spacing: 6) {
                if let date {
                    DatePicker(
                        "",
                        selection: Binding(
                            get: { date },
                            set: { onChange($0, hasTime) }
                        ),
                        displayedComponents: hasTime ? [.date, .hourAndMinute] : [.date]
                    )
                    .labelsHidden()

                    Toggle(isOn: Binding(
                        get: { hasTime },
                        set: { wantsTime in
                            onChange(
                                wantsTime ? defaultTime(on: date) : date,
                                wantsTime
                            )
                        }
                    )) {
                        Image(systemName: "clock")
                    }
                    .toggleStyle(.button)
                    .help(hasTime ? "Remove the time — make it all-day" : "Add a time")

                    Button {
                        onChange(nil, false)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button("Set") {
                        onChange(Calendar.current.startOfDay(for: Date()), false)
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    /// A day gaining a time starts at the top of the working day, not midnight.
    private func defaultTime(on day: Date) -> Date {
        Calendar.current.date(
            bySettingHour: Preferences.shared.workdayStartHour,
            minute: 0,
            second: 0,
            of: day
        ) ?? day
    }
}

private struct OptionalDateRow: View {
    var title: String
    @Binding var date: Date?
    var onCommit: () -> Void

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                if let unwrapped = date {
                    DatePicker("", selection: Binding(
                        get: { unwrapped },
                        set: { date = $0; onCommit() }
                    ), displayedComponents: [.date])
                        .labelsHidden()
                    Button {
                        date = nil
                        onCommit()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button("Set") {
                        date = Calendar.current.startOfDay(for: Date())
                        onCommit()
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }
}

/// Wraps chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var size = CGSize(width: 0, height: 0)
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let itemSize = subview.sizeThatFits(.unspecified)
            if lineWidth + itemSize.width > maxWidth, lineWidth > 0 {
                size.width = max(size.width, lineWidth - spacing)
                size.height += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += itemSize.width + spacing
            lineHeight = max(lineHeight, itemSize.height)
        }
        size.width = max(size.width, lineWidth - spacing)
        size.height += lineHeight
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let itemSize = subview.sizeThatFits(.unspecified)
            if x + itemSize.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(itemSize))
            x += itemSize.width + spacing
            lineHeight = max(lineHeight, itemSize.height)
        }
    }
}
