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
        HStack(spacing: 8) {
            if indent > 0 {
                Spacer().frame(width: CGFloat(indent) * 18)
            }

            Toggle(isOn: Binding(
                get: { todo.isCompleted },
                set: { _ in model.toggleCompleted(todo.id) }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()

            if editingID == todo.id {
                TextField("Title", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .focused($isEditing)
                    .onSubmit(commit)
                    .onChange(of: isEditing) { _, focused in if !focused { commit() } }
            } else {
                Text(todo.title)
                    .strikethrough(todo.isCompleted)
                    .foregroundStyle(todo.isCompleted ? .secondary : .primary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            trailingMetadata

            Button {
                model.inspectedID = todo.id
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(isHovering ? Color.secondary : Color.clear)
            .help("Show details (⌘I)")
        }
        .padding(.vertical, 2)
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

    @ViewBuilder
    private var trailingMetadata: some View {
        HStack(spacing: 8) {
            if !detail.children.isEmpty {
                Text("\(detail.completedChildCount)/\(detail.children.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let symbol = todo.priority.symbolName {
                Image(systemName: symbol)
                    .font(.caption2)
                    .foregroundStyle(todo.priority == .high ? Color.orange : .secondary)
            }

            ForEach(detail.tags.prefix(3)) { tag in
                TagChip(tag: tag)
            }

            if let project = detail.project, indent == 0, !isViewingProject(project) {
                HStack(spacing: 4) {
                    Dot(colorHex: project.colorHex, size: 6)
                    Text(project.name).font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            if let estimate = todo.estimateMinutes {
                Text(Format.duration(estimate))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !detail.blocks.isEmpty, let first = detail.blocks.first {
                Label(Format.time(first.startAt), systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let due = todo.dueAt {
                DueBadge(date: due, isCompleted: todo.isCompleted)
            }
        }
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
