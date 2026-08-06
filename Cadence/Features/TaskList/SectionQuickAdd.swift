import SwiftUI

/// The inline "add here" row at the foot of a day section. Adding inside a day
/// is how a date gets set without opening anything — the section already knows
/// which day it stands for.
struct SectionQuickAdd: View {
    @Environment(AppModel.self) private var model

    var date: Date?

    @State private var text = ""
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isFocused)
                .onSubmit(add)
        }
        .padding(.vertical, 2)
        .opacity(isFocused || isHovering || !text.isEmpty ? 1 : 0.35)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { isFocused = true }
    }

    private var placeholder: String {
        date == nil ? "Add task" : "Add task"
    }

    private func add() {
        let parsed = CaptureParser.parse(text)
        guard !parsed.isEmpty else { return }

        // A date typed into the text wins over the section it was typed in.
        let typed = parsed.scheduledAt ?? parsed.dueAt
        model.createTodo(
            title: parsed.title,
            tagNames: parsed.tagNames,
            priority: parsed.priority,
            estimateMinutes: parsed.estimateMinutes,
            dueAt: typed ?? date,
            scheduledAt: parsed.scheduledAt
        )
        text = ""
        // Stay focused so several tasks can be typed in a row.
        isFocused = true
    }
}
