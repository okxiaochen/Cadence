import SwiftUI

/// How this list is arranged, above the list it arranges.
///
/// This started life as a toolbar item and was never found: the window toolbar
/// put it past the search field, at the far right of a 1400pt window, while the
/// list it governed was on the left. Controls belong beside the thing they act
/// on. It also gives the list pane a header of the same height as the
/// calendar's, so the two line up in Split mode.
struct TodoListHeaderBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 8) {
            // Says what the list is currently doing, not what the control is —
            // "Group by Project" is only worth reading before you have chosen.
            Text(stateLabel)
                .font(Typography.rowMeta)
                .foregroundStyle(.secondaryText)
                .lineLimit(1)

            Spacer(minLength: 8)

            Menu {
                // `.inline`, emphatically: a plain Picker inside a macOS menu
                // collapses into a "Group By ▸" submenu, so the options stay
                // invisible until you hover the right row — which is why
                // grouping read as a feature that did not exist.
                Picker("Group By", selection: $model.query.grouping) {
                    ForEach(TodoGrouping.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)

                Picker("Sort By", selection: $model.query.sort) {
                    ForEach(TodoSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)

                Divider()
                Toggle("Show Completed", isOn: $model.query.showsCompleted)
                Divider()
                // Each list keeps its own arrangement, so name the one being
                // changed: picking "Project" here and finding Today untouched
                // would otherwise read as a bug.
                Text("Applies to \(listName)")
            } label: {
                Label("Group & Sort", systemImage: "line.3.horizontal.decrease")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Group, sort, and show completed — remembered for this list")
        }
        .padding(.horizontal, Metrics.comfortable)
        .padding(.vertical, Metrics.regular)
    }

    /// How the list is arranged — and nothing when it is arranged the default
    /// way. The list's *name* is deliberately absent: the window title already
    /// says it, and saying it twice is what makes a header feel like furniture.
    private var stateLabel: String {
        let grouping = model.query.resolvedGrouping
        let sort = model.query.sort
        var parts: [String] = []
        if grouping != .none { parts.append("By \(grouping.title.lowercased())") }
        if sort != .manual { parts.append("sorted by \(sort.title.lowercased())") }
        if model.query.showsCompleted { parts.append("with completed") }
        return parts.joined(separator: ", ")
    }

    private var listName: String {
        switch model.query.selection {
        case .smart(let list): list.title
        case .project(let id): model.projects.first { $0.id == id }?.name ?? "Project"
        case .tag(let id): model.tags.first { $0.id == id }.map { "#\($0.name)" } ?? "Tag"
        }
    }
}
