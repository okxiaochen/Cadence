import SwiftUI

/// Past conversations, as the sidebar of the chat workspace.
///
/// The same rows the history popover shows, promoted out of it. A popover was
/// right while the assistant was a column beside the work; once talking to it
/// *is* the work, hiding what you have said behind a clock icon means the
/// second thing anybody wants to do — find the conversation from Tuesday — is
/// the one thing that takes a click to discover.
struct ConversationSidebar: View {
    @Environment(AgentSession.self) private var session

    @State private var conversations: [AIConversation] = []

    var body: some View {
        List {
            ForEach(conversations) { conversation in
                row(conversation)
                    .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Button {
                    session.startNewConversation()
                } label: {
                    Label("New conversation", systemImage: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .font(Typography.rowTitle)
                .disabled(session.isEmptyConversation || session.status.isRunning)
                Spacer()
            }
            .padding(.horizontal, Metrics.comfortable)
            .padding(.vertical, Metrics.regular)
        }
        // Rebuilt whenever a turn finishes: a conversation started from the
        // desktop pet, or a run that started itself overnight, should be in the
        // list without the window having been reopened.
        .onAppear { reload() }
        .onChange(of: session.conversationID) { _, _ in reload() }
        .onChange(of: session.status.isRunning) { _, _ in reload() }
    }

    private func reload() {
        conversations = session.conversations()
    }

    private func row(_ conversation: AIConversation) -> some View {
        let isOpen = conversation.id == session.conversationID
        return Button {
            session.open(conversation)
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
        // The open one is marked with a fill rather than a word, so the list
        // reads as a list of places rather than a list with a note in it.
        .background(isOpen ? Color.accentColor.opacity(0.14) : .clear)
        .contextMenu {
            Button("Delete", role: .destructive) {
                session.deleteConversation(conversation)
                reload()
            }
        }
    }
}
