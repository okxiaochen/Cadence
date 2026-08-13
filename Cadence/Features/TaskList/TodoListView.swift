import SwiftUI

extension Notification.Name {
    /// ⌘N. The menu command lives in the app's Commands, the composer lives in
    /// whichever list is on screen, and a Scene cannot reach into a View's
    /// `@FocusState` — so the two are joined by a notification.
    static let focusComposer = Notification.Name("dev.xiaochen.Cadence.focusComposer")
}

struct TodoListView: View {
    @Environment(AppModel.self) private var model

    @State private var editingID: String?
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            TodoListHeaderBar()
            if model.isEmpty && model.query.searchText.isEmpty {
                emptyState
            } else {
                list
            }
            composer
        }
        .navigationTitle(navigationTitle)
        .searchable(text: $model.query.searchText, placement: .toolbar, prompt: "Search tasks")
        .onDeleteCommand(perform: deleteSelection)
        // The toolbar's + is gone — the composer at the bottom of the list is
        // already a permanent, visible "add a task" affordance, and a second
        // one across the window said the same thing again. ⌘N comes from the
        // File menu instead and lands the caret in that composer.
        .onReceive(NotificationCenter.default.publisher(for: .focusComposer)) { _ in
            isComposerFocused = true
        }
    }

    // MARK: - List

    private var list: some View {
        @Bindable var model = model

        return List(selection: $model.selection) {
            ForEach(model.sections) { section in
                // Deliberately not a `Section`. A List pins its headers and
                // paints an opaque bar behind whichever one is stuck to the
                // top — a surface the window material cannot show through, and
                // the brightest thing in the pane. The heading scrolls with its
                // own tasks instead.
                if !section.title.isEmpty {
                    sectionHeader(section)
                        .selectionDisabled()
                        .listRowSeparator(.hidden)
                }
                rows(for: section)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(for: Array(ids))
        }
    }

    /// Dragging rows around only means something in manual order; under any
    /// other sort the list would immediately put them back.
    private var canReorder: Bool { model.query.sort == .manual }

    /// A day heading doubles as a drop target: dragging a task onto "Tomorrow"
    /// moves it to that day, keeping whatever time it already had.
    @ViewBuilder
    private func sectionHeader(_ section: TodoSection) -> some View {
        let header = SectionHeader(
            title: section.title,
            count: section.items.count,
            symbolName: section.symbolName,
            colorHex: section.colorHex
        )
        .frame(maxWidth: .infinity, alignment: .leading)

        if let date = section.date {
            header.todoDropTarget { ids in model.moveToDay(date, for: ids) }
        } else {
            header
        }
    }

    @ViewBuilder
    private func rows(for section: TodoSection) -> some View {
        ForEach(section.items) { item in
            // On macOS this has to be set per row; applied to the List it is
            // quietly ignored and every row keeps its rule.
            TodoRowView(detail: item, editingID: $editingID, indent: 0)
                .tag(item.id)
                .listRowSeparator(.hidden)
                .todoReorderTarget(isEnabled: canReorder) { ids, placeAfter in
                    model.reorder(ids, relativeTo: item.id, placeAfter: placeAfter, day: section.date)
                }

            ForEach(item.children) { child in
                TodoRowView(detail: child, editingID: $editingID, indent: 1)
                    .tag(child.id)
                    .listRowSeparator(.hidden)
                    .todoReorderTarget(isEnabled: canReorder) { ids, placeAfter in
                        model.reorder(ids, relativeTo: child.id, placeAfter: placeAfter)
                    }
            }
        }

        if section.acceptsQuickAdd {
            SectionQuickAdd(date: section.date)
                .selectionDisabled()
                .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: [String]) -> some View {
        if !ids.isEmpty {
            Button("Complete") { model.setStatus(.done, for: ids) }
            if ids.count == 1 {
                Button(model.isTiming(ids[0]) ? "Stop Timer" : "Start Timer") {
                    model.toggleTimer(for: ids[0])
                }
            }
            Menu("Priority") {
                ForEach(Priority.allCases, id: \.self) { priority in
                    Button(priority.title) { model.setPriority(priority, for: ids) }
                }
            }
            Menu("Move to Project") {
                Button("No Project") { model.setProject(nil, for: ids) }
                Divider()
                ForEach(model.projects) { project in
                    Button(project.name) { model.setProject(project.id, for: ids) }
                }
            }
            if ids.count == 1 {
                Button("Add Subtask") { model.addSubtask(to: ids[0]) }
            }
            Divider()
            Button("Delete", role: .destructive) { model.delete(ids: ids) }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        CaptureField(contextChips: contextChips, isFocused: $isComposerFocused) { parsed in
            addTask(parsed)
        }
        .padding(.horizontal, Metrics.loose)
        .padding(.vertical, Metrics.comfortable)
        // A hairline, not a bar: one more filled surface is one more thing for
        // the eye to account for, and it blocked the window material.
        .overlay(alignment: .top) {
            Rectangle().fill(.hairline).frame(height: 1)
        }
    }

    /// What the current list will add for you, so it is visible before you
    /// press return rather than a surprise afterwards.
    private var contextChips: [String] {
        var chips: [String] = []
        if let id = model.currentProjectID,
           let project = model.projects.first(where: { $0.id == id }) {
            chips.append("@\(project.name)")
        }
        chips.append(contentsOf: model.currentTagNames.map { "#\($0)" })
        if let date = model.currentDefaultDate {
            chips.append(Format.relativeDue(date))
        }
        return chips
    }

    private var emptyState: some View {
        VStack(spacing: Metrics.regular) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.quaternary)
            VStack(spacing: Metrics.tight) {
                Text("Nothing here")
                    .font(.system(size: 14, weight: .medium))
                Text("Add a task below, or press ⌥Space anywhere.")
                    .font(Typography.rowMeta)
                    .foregroundStyle(.tertiaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    private var navigationTitle: String {
        switch model.query.selection {
        case .smart(let list): list.title
        case .project(let id): model.projects.first { $0.id == id }?.name ?? "Project"
        case .tag(let id): model.tags.first { $0.id == id }.map { "#\($0.name)" } ?? "Tag"
        }
    }

    // MARK: - Actions

    private func addTask(_ parsed: ParsedCapture) {
        model.createTodo(
            title: parsed.title,
            projectID: projectID(named: parsed.projectName),
            tagNames: parsed.tagNames,
            priority: parsed.priority,
            estimateMinutes: parsed.estimateMinutes,
            dueAt: parsed.dueAt,
            scheduledAt: parsed.scheduledAt
        )
    }

    private func projectID(named name: String?) -> String? {
        guard let name else { return nil }
        return model.projects.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }?.id
            ?? model.projects.first { $0.name.localizedCaseInsensitiveContains(name) }?.id
    }

    private func deleteSelection() {
        model.delete(ids: Array(model.selection))
    }
}
