import SwiftUI

/// The companion itself: a small face on the desktop, and the day behind it.
///
/// The first version showed a count on hover, which answered "how many" when
/// the question was "what". It shows the list now — tasks and calendar events
/// in one column, because a day does not arrive in two.
///
/// **Idle motion is budgeted, not free.** A circle breathing continuously with
/// `repeatForever` measured 17–19% of a core; the same circle held still costs
/// 0.0%. So it breathes in short bursts with long gaps rather than forever, and
/// stops entirely while the panel is open — nothing should be moving under text
/// somebody is reading.
/// Built once and left alone.
///
/// The first version rebuilt the whole hosting view on every refresh, which
/// threw away every piece of `@State` it owned — the pin, the hover, and a
/// half-typed line — once a minute and after every action. Reading the model
/// directly means SwiftUI updates what changed and keeps the rest.
struct PetView: View {
    let model: AppModel
    let preferences: Preferences
    let session: AgentSession
    var onOpen: () -> Void

    /// Ticks so the clock-dependent parts stay current. One state change a
    /// minute, which is all the companion's own precision needs.
    @State private var now = Date()

    private var status: PetStatus {
        model.petStatus(now: now, breakAfterMinutes: preferences.breakAfterMinutes)
    }

    private var prompts: [PetPrompt] { preferences.petPrompts.filter(\.isUsable) }
    private var isThinking: Bool { session.status.isRunning }
    /// The exchange so far, newest last. Shown rather than just the final
    /// reply: an answer with no question above it cannot be argued with, and
    /// arguing is most of what a plan needs.
    private var thread: [ChatMessage] {
        Array(session.messages.filter { $0.role != .system }.suffix(8))
    }

    @State private var isOverFace = false
    @State private var isOverPanel = false
    @State private var isPinned = false
    @State private var isOpen = false
    @State private var closing: Task<Void, Never>?
    @State private var draft = ""
    @State private var breathing = false
    @FocusState private var isTyping: Bool

    /// Opens at once, closes after a beat.
    ///
    /// The delay covers the gap between the face and the panel: crossing eight
    /// points of empty space leaves both, and without it the panel would shut
    /// on the way to the thing you were reaching for.
    private func setOpen() {
        // `isThinking` belongs here as a floor: a request that outlives its
        // own panel is one whose answer nobody sees.
        let wanted = isOverFace || isOverPanel || isPinned || isTyping || isThinking
        closing?.cancel()
        guard !wanted else { return isOpen = true }
        closing = Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            isOpen = false
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if isOpen {
                panel
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .onHover { isOverPanel = $0; setOpen() }
            } else if status.wantsAttention {
                bubble(status.headline).transition(.opacity)
            }

            face
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(10)
        .animation(.snappy(duration: 0.18), value: isOpen)
        .animation(.snappy(duration: 0.25), value: status.mood)
        // Deliberately *not* on the enclosing stack: it fills the whole window,
        // so hovering it opened the panel while the pointer was still a long
        // way from the companion.
        .onChange(of: isTyping) { _, typing in
            if typing { isPinned = true }
            setOpen()
        }
        .onChange(of: isOpen) { _, open in if open { model.noteEventAnswered() } }
        .onChange(of: isThinking) { _, _ in setOpen() }
        .onExitCommand {
            isPinned = false
            isTyping = false
            setOpen()
        }
        .task { await breathe() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                now = Date()
            }
        }
    }

    /// Short movement, long stillness — and none at all while the panel is up.
    ///
    /// The gap is what makes this affordable: a continuous loop redraws every
    /// frame forever, this redraws for about a second at a time.
    private func breathe() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64.random(in: 5_000_000_000...9_000_000_000))
            guard !Task.isCancelled, !isOpen else { continue }
            withAnimation(.easeInOut(duration: 0.55)) { breathing = true }
            try? await Task.sleep(nanoseconds: 550_000_000)
            withAnimation(.easeInOut(duration: 0.55)) { breathing = false }
        }
    }

    /// Asking pins the panel.
    ///
    /// A run takes twenty seconds to a minute, and the pointer does not stay
    /// still that long. Without this, asking for something and then moving the
    /// mouse loses both the progress and the answer — you would have to ask
    /// again to find out what happened the first time.
    ///
    /// It stays pinned afterwards rather than closing on its own: the reply is
    /// the reason the question was asked, and a panel that clears itself while
    /// you are reading is the same bug one step later.
    private func ask(_ text: String) {
        isPinned = true
        setOpen()
        handle(text)
    }

    /// One line in, two possible meanings. Anything that reads as a task
    /// becomes one immediately — capture should not cost a model call and half
    /// a minute of waiting — and everything else is a question.
    private func handle(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if PetView.looksLikeATask(trimmed) {
            let parsed = CaptureParser.parse(trimmed)
            if !parsed.isEmpty {
                model.createTodo(
                    title: parsed.title,
                    tagNames: parsed.tagNames,
                    priority: parsed.priority,
                    estimateMinutes: parsed.estimateMinutes,
                    dueAt: parsed.dueAt,
                    scheduledAt: parsed.scheduledAt
                )
                return
            }
        }
        session.send(trimmed, surface: .chat)
    }

    private func toggleTimer() {
        if let running = model.runningEntries.first {
            model.stopTimer(for: running.taskID)
        } else if case .underway(let item) = model.agendaFocus() {
            model.toggleTimer(for: item.todo.id)
        } else if case .next(let item) = model.agendaFocus() {
            model.toggleTimer(for: item.todo.id)
        }
    }

    /// A question ends in a question mark, or asks for something to be done; a
    /// task is a noun phrase. Allowed to be wrong, and leaning towards capture:
    /// guessing that way makes a visible task and one click to undo, guessing
    /// the other costs half a minute of waiting.
    static func looksLikeATask(_ text: String) -> Bool {
        if text.hasSuffix("?") || text.hasSuffix("？") { return false }
        if text.split(separator: " ").count > 12 { return false }
        let asks = ["plan ", "what ", "when ", "how ", "why ", "show ", "tell ",
                    "move ", "reschedule ", "summarise ", "summarize ", "check ",
                    "帮我", "看看", "整理", "安排", "什么", "怎么"]
        let lowered = text.lowercased()
        return !asks.contains { lowered.hasPrefix($0) || lowered.contains($0) }
    }

    // MARK: - The face

    private var face: some View {
        ZStack {
            Circle()
                .fill(status.mood.tint.gradient)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)

            // The gap does the work: eyes near the middle, mouth below it.
            // Both sat too high when the group was centred as one.
            VStack(spacing: 9) {
                HStack(spacing: 11) { eye; eye }
                mouth
            }
            .offset(y: -3)

            if status.openToday > 0 {
                Text("\(status.openToday)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.35), in: Capsule())
                    .offset(x: 20, y: 20)
            }
        }
        .frame(width: 56, height: 56)
        .scaleEffect(breathing ? 1.05 : 1.0)
        .contentShape(Circle())
        .onHover { isOverFace = $0; setOpen() }
        .onTapGesture { isPinned.toggle(); setOpen() }
    }

    /// Eyes carry the mood, which keeps every state a single frame.
    @ViewBuilder
    private var eye: some View {
        switch status.mood {
        case .restDue: Capsule().fill(.black.opacity(0.75)).frame(width: 9, height: 2.5)
        case .working: Capsule().fill(.black.opacity(0.8)).frame(width: 7, height: 6)
        case .behind: Circle().fill(.black.opacity(0.8)).frame(width: 9, height: 9)
        case .clear, .idle: Circle().fill(.black.opacity(0.75)).frame(width: 8, height: 8)
        }
    }

    /// The mouth does the mood; the eyes only agree with it. Two dots can look
    /// blank or alarmed and not much else, and a face that cannot smile is not
    /// company.
    @ViewBuilder
    private var mouth: some View {
        switch status.mood {
        case .clear:
            // Grinning, and the only one that is filled.
            Smile(curve: 9)
                .fill(.black.opacity(0.72))
                .frame(width: 18, height: 9)
        case .idle:
            Smile(curve: 5)
                .stroke(.black.opacity(0.65), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .frame(width: 15, height: 6)
        case .working:
            // Straight: concentrating, not unhappy.
            Capsule().fill(.black.opacity(0.6)).frame(width: 10, height: 1.8)
        case .restDue:
            // A yawn.
            Ellipse().fill(.black.opacity(0.6)).frame(width: 8, height: 10)
        case .behind:
            Smile(curve: -5)
                .stroke(.black.opacity(0.65), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .frame(width: 15, height: 6)
        }
    }

    // MARK: - The day

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(status.headline)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(status.timingMinutes == nil ? "Start" : "Stop") { toggleTimer() }
                    .buttonStyle(.link)
                    .font(.caption)
                if isPinned {
                    // Only while pinned: otherwise it is a control for undoing
                    // something the pointer already does by leaving.
                    Button {
                        isPinned = false
                        isTyping = false
                        setOpen()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 11)
            .padding(.bottom, 8)

            if status.today.isEmpty {
                Text("Nothing on today.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(status.today) { line in
                            row(line)
                        }
                    }
                    .padding(.vertical, 4)
                }
                // A fixed height, not a maximum: a panel that resizes as the
                // day fills up moves under the pointer.
                // Shorter once there is a conversation to make room for, so
                // the panel does not grow past the screen.
                .frame(height: min(CGFloat(status.today.count) * 30 + 8,
                                   thread.isEmpty ? 240 : 110))
            }

            Divider()

            if !prompts.isEmpty {
                // Buttons rather than features: what is worth asking depends on
                // what somebody has connected, so the app ships the way to ask.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(prompts) { saved in
                            Button(saved.title) { ask(saved.prompt) }
                                .buttonStyle(.borderless)
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.quaternary.opacity(0.6), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.vertical, 7)
                .disabled(isThinking)
                .opacity(isThinking ? 0.4 : 1)

                Divider()
            }

            if isThinking {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            } else {
                if !thread.isEmpty {
                    conversation
                }

                // One field for both: a line that parses as a task becomes one
                // without waiting on a model, and anything else is a question.
                // Making the user choose which they meant would be asking them
                // to know how it works.
                HStack(spacing: 6) {
                    Image(systemName: "sparkle").foregroundStyle(.secondary)
                    TextField(thread.isEmpty ? "Add a task, or ask…" : "Reply…",
                              text: $draft)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .focused($isTyping)
                        .onSubmit {
                            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            ask(text)
                            draft = ""
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
        }
        .frame(width: 268, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    /// Scrolls, and follows the newest message. The first version truncated
    /// the reply at four lines with no way to see the rest, which is a poor
    /// answer to a paragraph explaining why it could not do what was asked.
    private var conversation: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack {
                Text("Conversation")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Clear") { session.startNewConversation() }
                    .buttonStyle(.link)
                    .font(.caption2)
            }
            .padding(.horizontal, 12)
            .padding(.top, 7)

            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(thread) { message in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(message.role == .user ? "You" : "Cadence")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.tertiary)
                                Text(message.text)
                                    .font(.caption)
                                    .foregroundStyle(message.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 170)
                .onChange(of: thread.count) { _, _ in
                    withAnimation { scroller.scrollTo(thread.last?.id, anchor: .bottom) }
                }
                .onAppear { scroller.scrollTo(thread.last?.id, anchor: .bottom) }
            }
        }
    }

    private func row(_ line: PetStatus.Line) -> some View {
        HStack(spacing: 7) {
            switch line.kind {
            case .task:
                Button { model.toggleCompleted(line.id) } label: {
                    Image(systemName: line.isDone ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(line.isDone ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
            case .event:
                Image(systemName: "calendar")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 13)
            }

            Text(line.title)
                .font(.caption)
                .lineLimit(1)
                .strikethrough(line.isDone)

            Spacer(minLength: 4)

            if line.daysLate > 0 {
                Text("\(line.daysLate)d")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
            } else if let at = line.at {
                Text(Format.time(at))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func bubble(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.quaternary))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .frame(maxWidth: 220, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A curve between two corners. Positive smiles, negative does not.
private struct Smile: Shape {
    var curve: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control: CGPoint(x: rect.midX, y: rect.midY + curve)
        )
        return path
    }
}

private extension PetStatus.Mood {
    var tint: Color {
        switch self {
        case .idle: .teal
        case .working: .blue
        case .restDue: .orange
        case .behind: .pink
        case .clear: .green
        }
    }
}

extension PetStatus {
    /// Whether it should say something without being asked. Deliberately narrow:
    /// an idle day is not news, and a companion that comments on nothing in
    /// particular is one you stop reading.
    var wantsAttention: Bool {
        if breakAdvice.isDue { return true }
        if let event = nextEvent, event.minutesAway <= 10 { return true }
        if justEnded != nil { return true }
        return false
    }
}
