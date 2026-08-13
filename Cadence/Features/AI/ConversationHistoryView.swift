import SwiftUI

/// Past conversations with the assistant.
///
/// Every turn was already being written to `ai_run` for attribution; this is
/// that table read back the way you remember it — by how the conversation
/// opened, not by which run it was.
struct ConversationHistoryView: View {
    @Environment(AgentSession.self) private var session
    @Binding var isPresented: Bool

    /// Loaded once when the popover opens, rather than on every redraw: a
    /// database read inside `body` runs on each pass over the list.
    @State private var conversations: [AIConversation] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if conversations.isEmpty {
                Text("No conversations yet.")
                    .font(Typography.rowMeta)
                    .foregroundStyle(.tertiaryText)
                    .padding(Metrics.comfortable)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(conversations) { conversation in
                            row(conversation)
                            Divider().opacity(0.4)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 300)
        .onAppear { conversations = session.conversations() }
    }

    private func row(_ conversation: AIConversation) -> some View {
        Button {
            session.open(conversation)
            isPresented = false
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayTitle)
                    .font(Typography.rowTitle)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: Metrics.snug) {
                    Text(Format.daysAgo(conversation.lastAt))
                    if conversation.turns > 1 {
                        Text("· \(conversation.turns) turns")
                    }
                    if conversation.id == session.conversationID {
                        Text("· open")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .font(Typography.rowMeta)
                .foregroundStyle(.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.comfortable)
            .padding(.vertical, Metrics.regular)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete", role: .destructive) {
                session.deleteConversation(conversation)
                conversations = session.conversations()
            }
        }
    }
}
