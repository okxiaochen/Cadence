import SwiftUI

struct AIPanelView: View {
    /// Whether this is the window rather than a column beside it.
    ///
    /// One view in two shapes rather than two views: everything about a
    /// conversation is the same either way, and the differences are all about
    /// width — a column is capped so it cannot crush the calendar next to it,
    /// and a window is uncapped but has to stop its text from setting in
    /// hundred-character lines, which nobody can read.
    var isPrimary = false

    @Environment(AppModel.self) private var model
    @Environment(AgentSession.self) private var session

    @State private var input = ""
    @State private var showsDetails = false
    @State private var showsHistory = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let problem = session.configurationProblem {
                configurationBanner(problem)
            }

            transcript
            Divider()

            if let proposal = session.proposal {
                ProposalReviewView(proposal: proposal)
                Divider()
            }

            composer
                // The same measure the transcript uses. A full-width field
                // under a centred column reads as two panes that happen to be
                // stacked, and the eye has to travel to the left edge to type
                // a reply to something set in the middle.
                .frame(maxWidth: isPrimary ? 784 : .infinity)
                .frame(maxWidth: .infinity, alignment: isPrimary ? .center : .leading)
        }
        // A capped maximum when it is a column, or the panel is as flexible as
        // the workspace beside it and an `HStack` splits the window down the
        // middle — which crushes the calendar past its own minimum and the two
        // overlap. As the window it takes what it is given.
        .frame(
            minWidth: Self.minimumWidth,
            idealWidth: isPrimary ? nil : 340,
            maxWidth: isPrimary ? nil : 460
        )
    }

    static let minimumWidth: CGFloat = 300

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text("Assistant").font(.headline)
            Spacer()
            if session.status.isRunning {
                ProgressView().controlSize(.small)
                Button("Stop") { session.cancel() }
                    .controlSize(.small)
            }
            Button {
                session.startNewConversation()
                isInputFocused = true
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .quietIconButton()
            .disabled(session.isEmptyConversation || session.status.isRunning)
            .help("New conversation")

            Button { showsHistory.toggle() } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .quietIconButton()
            .help("Past conversations")
            .popover(isPresented: $showsHistory, arrowEdge: .bottom) {
                ConversationHistoryView(isPresented: $showsHistory)
                    .environment(session)
            }

            Menu {
                Button("Show Run Details") { showsDetails = true }
                    .disabled(session.commandLine.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .sheet(isPresented: $showsDetails) { RunDetailView() }
    }

    private func configurationBanner(_ problem: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(problem).font(.caption)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.12))
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if session.messages.isEmpty { suggestions }

                    ForEach(session.messages) { message in
                        MessageBubble(message: message).id(message.id)
                    }

                    if session.status.isRunning {
                        runningIndicator.id("running")
                    }
                }
                .padding(12)
                // A measure rather than the full width. Set across a wide
                // window, a paragraph runs to well over a hundred characters
                // a line and the eye loses its place returning to the left.
                .frame(maxWidth: isPrimary ? 760 : .infinity, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: isPrimary ? .center : .leading)
            }
            .onChange(of: session.messages.count) { _, _ in
                if let last = session.messages.last { scroller.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: session.toolCalls.count) { _, _ in
                scroller.scrollTo("running", anchor: .bottom)
            }
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try asking")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Self.starters, id: \.self) { starter in
                Button {
                    session.send(starter, surface: .chat)
                } label: {
                    Text(starter)
                        .font(.callout)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(session.configurationProblem != nil)
            }
        }
    }

    private static let starters = [
        "Plan my week around my meetings",
        "What's unscheduled and due this week?",
        "Today got wrecked — move what I missed into the rest of the week",
        "Which day am I most overloaded?"
    ]

    private var runningIndicator: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(session.toolCalls.enumerated()), id: \.offset) { _, call in
                HStack(spacing: 5) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption2)
                    Text(call.replacingOccurrences(of: "_", with: " "))
                        .font(.caption.monospaced())
                }
                .foregroundStyle(.secondary)
            }
            if session.toolCalls.isEmpty {
                Text("Thinking…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask, or describe what needs doing…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($isInputFocused)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }

            HStack(spacing: 6) {
                Button("Generate Todos") { send(surface: .generate) }
                    .help("Turn the text above into tasks")
                Button("Plan Week") {
                    session.send(
                        "Schedule everything unscheduled into this week, around my existing commitments.",
                        surface: .schedule
                    )
                }
                Spacer()
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .disabled(session.status.isRunning || session.configurationProblem != nil)
        }
        .padding(10)
        .background(.bar)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !session.status.isRunning
            && session.configurationProblem == nil
    }

    private func send() { send(surface: .chat) }

    private func send(surface: AISurface) {
        guard canSend else { return }
        session.send(input, surface: surface)
        input = ""
    }
}

// MARK: - Message

private struct MessageBubble: View {
    var message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            Text(message.text)
                .padding(8)
                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            // The assistant writes markdown, and the chat panel was showing it
            // as punctuation for the same reason the companion was.
            MarkdownText(source: message.text, font: .body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .system:
            HStack(spacing: 5) {
                Image(systemName: message.isError ? "exclamationmark.triangle" : "info.circle")
                Text(message.text)
            }
            .font(.caption)
            .foregroundStyle(message.isError ? Color.red : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Proposal review

struct ProposalReviewView: View {
    @Environment(AgentSession.self) private var session
    var proposal: Proposal

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Proposed changes")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(proposal.applicableChanges.count) of \(proposal.changes.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ForEach(proposal.changes) { reviewed in
                ChangeRow(reviewed: reviewed)
            }

            ForEach(proposal.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Discard") { session.discardProposal() }
                Spacer()
                Button("Apply \(proposal.applicableChanges.count)") { session.applyProposal() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(proposal.applicableChanges.isEmpty)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35))
    }
}

private struct ChangeRow: View {
    @Environment(AgentSession.self) private var session
    var reviewed: ReviewedChange

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if reviewed.isApplicable {
                Toggle(isOn: Binding(
                    get: { reviewed.isAccepted },
                    set: { session.setAccepted($0, for: reviewed.id) }
                )) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            } else {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(reviewed.summary)
                    .font(.callout)
                    .strikethrough(!reviewed.isApplicable)
                    .foregroundStyle(reviewed.isApplicable ? .primary : .secondary)
                if let detail = reviewed.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                if let rejection = reviewed.rejection {
                    // The model's mistakes stay visible rather than vanishing.
                    Text(rejection).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Run detail

private struct RunDetailView: View {
    @Environment(AgentSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run Details").font(.headline)

            Text("Command").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                Text(session.commandLine).font(.caption.monospaced()).textSelection(.enabled)
            }
            .frame(height: 40)

            Text("Output").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(session.rawOutput.isEmpty ? "—" : session.rawOutput)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 620, height: 460)
    }
}
