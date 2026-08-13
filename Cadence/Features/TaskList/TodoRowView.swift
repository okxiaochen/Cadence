import SwiftUI

struct TodoRowView: View {
    @Environment(AppModel.self) private var model

    var detail: TodoDetail
    @Binding var editingID: String?
    var indent: Int

    @State private var draftTitle = ""
    @State private var isHovering = false
    @FocusState private var isEditing: Bool

    private var todo: Todo { detail.todo }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.regular) {
            if indent > 0 {
                Spacer().frame(width: CGFloat(indent) * 20)
            }

            CircleCheckbox(
                isOn: todo.isCompleted,
                tint: detail.project.map { Color(hex: $0.colorHex) } ?? .accentColor
            ) {
                model.toggleCompleted(todo.id)
            }
            // Baseline alignment would hang the circle off the text baseline.
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }

            VStack(alignment: .leading, spacing: 2) {
                title
                // A second line only when there is something to put on it, so
                // a plain task stays a single tidy line.
                if !secondary.isEmpty { secondaryLine }
                if let preview = notesPreview { notesLine(preview) }
            }

            Spacer(minLength: Metrics.regular)

            trailing
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        // `simultaneousGesture`, not `onTapGesture`: the row already carries a
        // drag source and the List's own selection gesture, and a plain tap
        // gesture loses the arbitration to them.
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { model.inspectedID = todo.id }
        )
        .todoDragSource(todo.id)
        .onHover { isHovering = $0 }
        .onChange(of: editingID) { _, newValue in
            if newValue == todo.id { beginEditing() }
        }
    }

    // MARK: - Title

    @ViewBuilder
    private var title: some View {
        if editingID == todo.id {
            TextField("Title", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(Typography.rowTitle)
                .focused($isEditing)
                .onSubmit(commit)
                .onChange(of: isEditing) { _, focused in if !focused { commit() } }
        } else {
            Text(todo.title)
                .font(Typography.rowTitle)
                .strikethrough(todo.isCompleted, color: .secondaryText)
                .foregroundStyle(todo.isCompleted ? .secondaryText : .primary)
                .lineLimit(1)
        }
    }

    // MARK: - Secondary line

    /// Context that explains the task but is not the task: where it lives, how
    /// long it takes. Kept off the title line so scanning titles stays easy.
    private var secondary: [SecondaryItem] {
        var items: [SecondaryItem] = []

        if let project = detail.project, indent == 0, !isViewingProject(project) {
            items.append(.project(project))
        }
        for tag in detail.tags.prefix(3) {
            items.append(.tag(tag))
        }
        if !detail.children.isEmpty {
            items.append(.progress(detail.completedChildCount, detail.children.count))
        }
        if let estimate = todo.estimateMinutes, detail.blocks.isEmpty {
            items.append(.estimate(estimate))
        }

        // What has actually been put into this, as against what was planned.
        // Recomputed from `model.clock`, so a running timer counts up here
        // without this view owning a timer of its own.
        let progress = detail.progress
        if progress.isRunning {
            items.append(.timing(progress.trackedSeconds(now: model.clock)))
        } else if progress.trackedSeconds > 0 {
            items.append(.tracked(progress.trackedSeconds))
        }
        // "Sitting for days but moving every day" is only visible if the last
        // time it moved is on the row. Today's progress needs no announcement.
        if let last = progress.lastAt, !progress.isRunning,
           !Calendar.current.isDateInToday(last) {
            items.append(.lastProgress(last))
        }
        return items
    }

    /// The first line of the notes, so a task with context does not have to be
    /// opened to see it.
    private var notesPreview: String? {
        guard editingID != todo.id else { return nil }
        return detail.notesPreview
    }

    private func notesLine(_ text: String) -> some View {
        Text(text)
            .font(Typography.rowMeta)
            .foregroundStyle(.tertiaryText)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var secondaryLine: some View {
        HStack(spacing: Metrics.regular) {
            ForEach(secondary) { item in
                switch item {
                case .project(let project):
                    HStack(spacing: Metrics.tight) {
                        Dot(colorHex: project.colorHex, size: 6)
                        Text(project.name)
                    }
                case .tag(let tag):
                    Text("#\(tag.name)")
                        .foregroundStyle(Color(hex: tag.colorHex))
                case .progress(let done, let total):
                    Text("\(done)/\(total)")
                        .monospacedDigit()
                case .estimate(let minutes):
                    Text(Format.duration(minutes))
                        .monospacedDigit()
                case .tracked(let seconds):
                    Label(Format.duration(max(1, seconds / 60)), systemImage: "stopwatch")
                        .monospacedDigit()
                case .timing(let seconds):
                    Label(Format.duration(max(1, seconds / 60)), systemImage: "stopwatch.fill")
                        .monospacedDigit()
                        .foregroundStyle(Color.accentColor)
                case .lastProgress(let date):
                    Text(Format.daysAgo(date, now: model.clock))
                }
            }
        }
        .font(Typography.rowMeta)
        .foregroundStyle(.secondaryText)
        .lineLimit(1)
    }

    private enum SecondaryItem: Identifiable, Hashable {
        case project(Project)
        case tag(Tag)
        case progress(Int, Int)
        case estimate(Int)
        /// Time recorded against the task, and the same while it is running.
        case tracked(Int)
        case timing(Int)
        case lastProgress(Date)

        var id: String {
            switch self {
            case .project(let project): "p\(project.id)"
            case .tag(let tag): "t\(tag.id)"
            case .progress(let done, let total): "c\(done)/\(total)"
            case .estimate(let minutes): "e\(minutes)"
            // Not the seconds: an id that changes every tick makes SwiftUI
            // tear the view down and build a new one once a minute.
            case .tracked: "tracked"
            case .timing: "timing"
            case .lastProgress: "last"
            }
        }
    }

    // MARK: - Trailing

    /// When it happens, and priority. The two things worth aligning down the
    /// right edge so a list can be scanned vertically.
    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: Metrics.regular) {
            // Visible while timing, and on hover otherwise — the one control
            // that has to be reachable without opening anything.
            if isTiming || (isHovering && !todo.isCompleted) {
                Button {
                    model.toggleTimer(for: todo.id)
                } label: {
                    Image(systemName: isTiming ? "stop.circle.fill" : "play.circle")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(isTiming ? Color.accentColor : .secondaryText)
                .help(isTiming ? "Stop the timer" : "Start timing this task")
            }

            if let symbol = todo.priority.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(todo.priority == .high ? Color.orange : .secondaryText)
            }

            if let block = detail.blocks.first {
                Text(Format.time(block.startAt))
                    .font(Typography.time)
                    .foregroundStyle(.secondaryText)
            } else if let due = todo.dueAt {
                Text(Format.relativeDue(due))
                    .font(Typography.time)
                    .foregroundStyle(isOverdue(due) ? Color.red : .secondaryText)
            }

            Button {
                model.inspectedID = todo.id
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isHovering ? Color.secondaryText : Color.clear)
            .help("Show details (⌘I)")
        }
    }

    private var isTiming: Bool { model.isTiming(todo.id) }

    private func isOverdue(_ date: Date) -> Bool {
        !todo.isCompleted && date < Calendar.current.startOfDay(for: Date())
    }

    // MARK: - Editing

    private func beginEditing() {
        draftTitle = todo.title
        editingID = todo.id
        isEditing = true
    }

    private func commit() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != todo.title {
            var updated = todo
            updated.title = trimmed
            model.update(updated, actionName: "Rename Task")
        }
        if editingID == todo.id { editingID = nil }
    }

    private func isViewingProject(_ project: Project) -> Bool {
        model.query.selection == .project(project.id)
    }
}
