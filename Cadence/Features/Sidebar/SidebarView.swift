import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    @State private var isAddingProject = false
    @State private var newProjectName = ""
    @State private var newProjectColor = Palette.defaultProjectColor
    @State private var renamingProject: Project?

    var body: some View {
        @Bindable var model = model

        List(selection: Binding(
            get: { model.query.selection },
            set: { if let value = $0 { model.query.selection = value } }
        )) {
            Section {
                ForEach(SmartList.allCases) { list in
                    SidebarRow(
                        title: list.title,
                        symbolName: list.symbolName,
                        count: model.smartCounts[list] ?? 0
                    )
                    .tag(SidebarSelection.smart(list))
                    .dropTarget(.smart(list))
                }
            }

            Section {
                sidebarHeading("Projects")

                ForEach(model.projects) { project in
                    SidebarRow(
                        title: project.name,
                        colorHex: project.colorHex,
                        count: model.projectCounts[project.id] ?? 0
                    )
                    .tag(SidebarSelection.project(project.id))
                    .dropTarget(.project(project.id))
                    .contextMenu {
                        Button("Rename…") { renamingProject = project }
                        Button("Delete", role: .destructive) {
                            model.deleteProject(id: project.id)
                        }
                    }
                }

                Button {
                    isAddingProject = true
                } label: {
                    HStack(spacing: Metrics.snug) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 16)
                        Text("New Project")
                        Spacer()
                    }
                    .foregroundStyle(.tertiaryText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !model.tags.isEmpty {
                Section {
                    sidebarHeading("Tags")

                    ForEach(model.tags) { tag in
                        SidebarRow(
                            title: "#\(tag.name)",
                            colorHex: tag.colorHex,
                            count: model.tagCounts[tag.id] ?? 0
                        )
                        .tag(SidebarSelection.tag(tag.id))
                        .dropTarget(.tag(tag.id))
                        .contextMenu {
                            Button("Delete", role: .destructive) { model.deleteTag(id: tag.id) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        .sheet(isPresented: $isAddingProject) {
            ProjectEditor(
                title: "New Project",
                name: $newProjectName,
                colorHex: $newProjectColor
            ) {
                model.createProject(name: newProjectName, colorHex: newProjectColor)
                newProjectName = ""
                newProjectColor = Palette.defaultProjectColor
            }
        }
        .sheet(item: $renamingProject) { project in
            RenameProjectSheet(project: project) { updated in model.update(updated) }
        }
    }
}

// MARK: - Editors

private struct ProjectEditor: View {
    var title: String
    @Binding var name: String
    @Binding var colorHex: String
    var onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            SwatchPicker(selection: $colorHex)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onSave()
        dismiss()
    }
}

private struct RenameProjectSheet: View {
    @State var project: Project
    var onSave: (Project) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Project").font(.headline)
            TextField("Name", text: $project.name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            SwatchPicker(selection: $project.colorHex)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func save() {
        onSave(project)
        dismiss()
    }
}

/// The eight-swatch picker used for both projects and tags.
struct SwatchPicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Palette.choices, id: \.self) { hex in
                Circle()
                    .fill(Color(hex: hex))
                    .frame(width: 20, height: 20)
                    .overlay {
                        Circle()
                            .strokeBorder(.primary, lineWidth: selection == hex ? 2 : 0)
                    }
                    .onTapGesture { selection = hex }
            }
        }
    }
}

// MARK: - Dropping tasks onto the sidebar

private struct SidebarDropTarget: ViewModifier {
    @Environment(AppModel.self) private var model
    var selection: SidebarSelection

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            // A row's label does not fill the row, so the drop area is made
            // explicit — otherwise the gaps swallow the drop.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(isTargeted ? 0.25 : 0))
            )
            .onDrop(of: [TaskDrag.typeIdentifier], isTargeted: $isTargeted) { providers in
                TaskDrag.todoIDs(from: providers) { ids in
                    model.applyDrop(selection, to: ids)
                }
            }
    }
}

extension View {
    func dropTarget(_ selection: SidebarSelection) -> some View {
        modifier(SidebarDropTarget(selection: selection))
    }
}

// MARK: - Heading

extension SidebarView {
    /// A quiet heading inside the list rather than a `Section` title, whose
    /// stock styling is heavier than the rows it introduces.
    fileprivate func sidebarHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Typography.sectionHeader)
            .tracking(0.6)
            .foregroundStyle(.tertiaryText)
            .padding(.top, Metrics.comfortable)
            .padding(.bottom, 2)
            .selectionDisabled()
    }
}

// MARK: - Row

/// One sidebar entry.
///
/// Hand-built rather than `Label(…).badge(…)`: the stock badge is a heavy
/// pill that competes with the label it annotates, and a count is context, not
/// a notification.
private struct SidebarRow: View {
    var title: String
    var symbolName: String?
    var colorHex: String?
    var count: Int

    var body: some View {
        HStack(spacing: Metrics.regular) {
            Group {
                if let colorHex {
                    Dot(colorHex: colorHex, size: 8)
                } else if let symbolName {
                    Image(systemName: symbolName)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .frame(width: 16)

            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer(minLength: Metrics.snug)

            if count > 0 {
                Text("\(count)")
                    .font(Typography.count)
                    .foregroundStyle(.tertiaryText)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
