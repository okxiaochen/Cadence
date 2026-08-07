import SwiftUI

struct TodoListView: View {
    @Environment(AppModel.self) private var model

    @State private var editingID: String?
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            if model.isEmpty && model.query.searchText.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            composer
        }
        .navigationTitle(navigationTitle)
        .searchable(text: $model.query.searchText, placement: .toolbar, prompt: "Search tasks")
        .toolbar { toolbarContent }
        .onDeleteCommand(perform: deleteSelection)
    }

    // MARK: - List

    private var list: some View {
        @Bindable var model = model

        return List(selection: $model.selection) {
            ForEach(model.sections) { section in
                if section.title.isEmpty {
                    rows(for: section)
                } else {
                    Section {
                        rows(for: section)
                    } header: {
                        sectionHeader(section)
                    }
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(for: Array(ids))
        }
    }

    /// A day heading doubles as a drop target: dragging a task onto "Tomorrow"
    /// moves it to that day, keeping whatever time it already had.
    @ViewBuilder
    private func sectionHeader(_ section: TodoSection) -> some View {
        let header = HStack(spacing: 6) {
            if let colorHex = section.colorHex { Dot(colorHex: colorHex) }
            else if let symbol = section.symbolName { Image(systemName: symbol) }
            Text(section.title)
            Spacer()
            if !section.items.isEmpty {
                Text("\(section.items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
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
            TodoRowView(detail: item, editingID: $editingID, indent: 0)
                .tag(item.id)

            ForEach(item.children) { child in
                TodoRowView(detail: child, editingID: $editingID, indent: 1)
                    .tag(child.id)
            }
        }

        if section.acceptsQuickAdd {
            SectionQuickAdd(date: section.date)
                .selectionDisabled()
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: [String]) -> some View {
        if !ids.isEmpty {
            Button("Complete") { model.setStatus(.done, for: ids) }
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
        CaptureField(contextChips: contextChips) { parsed in
            addTask(parsed)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
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
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Nothing here")
                .font(.headline)
            Text("Add a task below, or press ⌥Space anywhere.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        @Bindable var model = model

        ToolbarItem {
            Menu {
                Picker("Group By", selection: $model.query.grouping) {
                    ForEach(TodoGrouping.allCases) { Text($0.title).tag($0) }
                }
                Picker("Sort By", selection: $model.query.sort) {
                    ForEach(TodoSort.allCases) { Text($0.title).tag($0) }
                }
                Divider()
                Toggle("Show Completed", isOn: $model.query.showsCompleted)
            } label: {
                Label("View Options", systemImage: "line.3.horizontal.decrease.circle")
            }
        }

        ToolbarItem {
            Button {
                isComposerFocused = true
            } label: {
                Label("New Task", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }

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
