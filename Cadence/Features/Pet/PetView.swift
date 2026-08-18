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
    let presence: PresenceTracker
    let scheduled: ScheduledPrompts
    var onOpen: () -> Void

    /// Ticks so the clock-dependent parts stay current. One state change a
    /// minute, which is all the companion's own precision needs.
    @State private var now = Date()

    private var status: PetStatus {
        model.petStatus(
            now: now,
            breakAfterMinutes: preferences.breakAfterMinutes,
            nudge: nudge
        )
    }

    private var nudge: PetNudge {
        PetNudge.decide(
            sittingMinutes: presence.sittingMinutes,
            minutesSinceWater: presence.minutesSinceWater,
            moveAfter: preferences.moveAfterMinutes,
            waterAfter: preferences.waterAfterMinutes,
            lastNudgedAt: presence.lastNudgedAt,
            now: now
        )
    }

    private var prompts: [PetPrompt] { preferences.petPrompts.filter(\.isUsable) }

    /// Whether this mood came with a loop of its own.
    private var hasAnimation: Bool {
        CatArtwork.animation(named: status.mood.assetName) != nil
    }

    /// The day shrinks to make room for whatever else has to be read. A panel
    /// that grows past the screen shows less, not more.
    private var listHeight: CGFloat {
        let hasProposal = session.proposal.map { !$0.isEmpty } ?? false
        if hasProposal { return 90 }
        return thread.isEmpty ? 240 : 110
    }
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
    /// Which row the pointer is on, so its timer button is the only one shown.
    @State private var hovered: String?
    /// Set when a run finishes while nobody is looking, so its result gets a
    /// bubble instead of being silently waiting behind a closed panel.
    @State private var unreadReply: String?
    @FocusState private var isTyping: Bool

    /// Opens at once, closes after a beat.
    ///
    /// The delay covers the gap between the face and the panel: crossing eight
    /// points of empty space leaves both, and without it the panel would shut
    /// on the way to the thing you were reaching for.
    private func setOpen() {
        // `isThinking` is deliberately *not* here. It was, on the reasoning
        // that an answer nobody sees is wasted — but that assumed every run
        // was short. A booking that waits for a slot can run for an hour, and
        // a panel that cannot be dismissed until it finishes is a panel that
        // owns the corner of your screen. It closes; the answer comes back as
        // a bubble.
        let wanted = isOverFace || isOverPanel || isPinned || isTyping
        closing?.cancel()

        guard !wanted else { return isOpen = true }
        closing = Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            isOpen = false
        }
    }

    /// How long a pin outlives the pointer.
    private static let awayCloseSeconds: Double = 5

    /// Whether somebody is still with it, asked of the world rather than
    /// inferred from events.
    ///
    /// The first attempt at the lease used `onHover` and `@FocusState`, and did
    /// not work in the app while passing a test that drove it synthetically.
    /// Both signals are *events*, and this is a borderless `.nonactivatingPanel`
    /// — a pointer that leaves quickly, or a click into another application,
    /// can leave the exit event unsent and the focus never resigned. Then
    /// `attending` is true forever and the panel is exactly as stuck as before,
    /// with more code.
    ///
    /// The keyboard was tried as a second signal and is no good either. This is
    /// a `.nonactivatingPanel` with `hidesOnDeactivate` off, so `isKeyWindow`
    /// stays **true** after you have switched to another application entirely —
    /// measured, with Cadence reporting itself inactive and the panel still
    /// claiming the keyboard. Focus in a window that never gives it up is not
    /// evidence of anything.
    ///
    /// So: the pointer, and nothing else. A half-typed line holds the lease
    /// separately, which covers the case this would have been for — somebody
    /// typing with the mouse parked elsewhere holds it from the first
    /// character, and an empty field they clicked and wandered off from is not
    /// attention by any reading.
    ///
    /// A position cannot fail to arrive. Polled twice a second, which for a
    /// comparison of two points is nothing.
    private var isAttending: Bool {
        guard let panel = NSApp.windows.first(where: {
            $0.identifier == PetWindowController.panelIdentifier
        }) else { return false }
        return panel.frame.contains(NSEvent.mouseLocation)
    }

    /// Lets the pin lapse once somebody has plainly gone.
    ///
    /// A half-typed line holds it open. The draft survives the panel closing,
    /// but watching it shut under your hands would not read like that, and
    /// there is no way to know from outside that it did not eat what you wrote.
    private func watchAway() async {
        var awayFor: Double = 0
        let step: Double = 0.5
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard isPinned else { awayFor = 0; continue }

            if isAttending || !draft.isEmpty {
                awayFor = 0
                continue
            }
            awayFor += step
            if awayFor >= Self.awayCloseSeconds {
                awayFor = 0
                isPinned = false
                isOverFace = false
                isOverPanel = false
                // Cleared too, or `setOpen` reads the stale focus of a field in
                // a window nobody is looking at and holds the panel open on the
                // strength of it.
                isTyping = false
                setOpen()
            }
        }
    }

    /// How long a bubble stays up on its own.
    ///
    /// Much longer than the panel's five seconds, and not tied to the pointer
    /// at all, because a remark is read with the eyes: for the whole time
    /// somebody is reading one, the mouse is exactly where they left it. Five
    /// seconds here would mean the companion says something and takes it back
    /// before it has been read, which is worse than it staying.
    private static let bubbleLifeSeconds: Double = 45

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if isOpen {
                panel
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .onHover { isOverPanel = $0; setOpen() }
            } else if let unreadReply {
                unreadBubble(unreadReply).transition(.opacity)
            } else if let announcement = scheduled.announcement {
                // What a scheduled question came back with. Above the body
                // nudges: this one was asked for, even if not just now.
                announcementBubble(scheduled.announcementTitle, announcement)
                    .transition(.opacity)
            } else if status.nudge.isSomething {
                // Answerable, because a reminder you cannot reply to is one you
                // get again in twenty minutes whether or not you acted on it.
                nudgeBubble(status.nudge).transition(.opacity)
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
        .onChange(of: isThinking) { _, nowThinking in
            // Finished while closed: say so rather than leaving the answer
            // behind a panel nobody has a reason to open.
            //
            // Two things it must not say. A scheduled check's reply is not for
            // here — `ScheduledPrompts` decides whether that was worth an
            // interruption, and this bubble sits *above* its announcement in
            // the chain, so showing it would cover the considered version with
            // the raw one. And a reply that means silence is silence by
            // whatever path it arrives: the bug this replaces popped a bubble
            // reading "SKIP".
            if !nowThinking, !isOpen, !scheduled.isAnswering,
               let last = session.messages.last, last.role == .assistant,
               !PetPrompt.isSilent(last.text) {
                unreadReply = last.text
            }
            setOpen()
        }
        .onChange(of: isOpen) { _, open in if open { unreadReply = nil } }
        .onChange(of: draft.isEmpty) { _, _ in setOpen() }
        // Both bubbles time out rather than waiting to be clicked. `task(id:)`
        // restarts the clock when the text changes, so a second remark gets its
        // own life rather than inheriting what was left of the first one's.
        .task(id: unreadReply) {
            guard unreadReply != nil else { return }
            try? await Task.sleep(nanoseconds: UInt64(Self.bubbleLifeSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            unreadReply = nil
        }
        .task(id: scheduled.announcement) {
            guard scheduled.announcement != nil else { return }
            try? await Task.sleep(nanoseconds: UInt64(Self.bubbleLifeSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            scheduled.dismiss()
        }
        .onExitCommand {
            isPinned = false
            isTyping = false
            setOpen()
        }
        .task { await breathe() }
        .task { await watchAway() }
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
            if hasAnimation {
                // The artwork is doing it properly. Nothing to fake.
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                continue
            }
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
    /// `title` is what the button said, which is the only place that knows it.
    /// Without it the conversation is listed under the instruction the button
    /// sent, and six weather checks are six identical rows of curl.
    private func ask(_ text: String, title: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isPinned = true
        setOpen()
        session.send(trimmed, surface: .chat, title: title)
    }

    /// What the text field does, which depends on what the text field says.
    ///
    /// With nothing said yet it reads "Add a task, or ask…" and guesses between
    /// the two. Once there is a conversation it reads "Reply…", and then it is
    /// a reply — no guessing.
    ///
    /// It used to guess either way, so answering "Approve it and let's do that"
    /// filed a task called *Approve it and let's do that* and left the question
    /// hanging. The guess is defensible for a first line and indefensible for
    /// an answer: there is a question directly above it, which is as much
    /// context as a rule ever gets.
    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if PetView.shouldCapture(trimmed, inConversation: !thread.isEmpty) {
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
        ask(trimmed)
    }

    /// A question ends in a question mark, or asks for something to be done; a
    /// task is a noun phrase. Allowed to be wrong, and leaning towards capture:
    /// guessing that way makes a visible task and one click to undo, guessing
    /// the other costs half a minute of waiting.
    /// Whether a typed line should be filed rather than sent.
    ///
    /// The conversation is the stronger signal and it wins outright. Guessing
    /// between the two is only reasonable while there is nothing above the
    /// field to answer; once there is, a line typed under a question is an
    /// answer to it, and "Approve it and let's do that" is not a task however
    /// much it parses like one.
    static func shouldCapture(_ text: String, inConversation: Bool) -> Bool {
        !inConversation && looksLikeATask(text)
    }

    static func looksLikeATask(_ text: String) -> Bool {
        if text.hasSuffix("?") || text.hasSuffix("？") { return false }
        if text.split(separator: " ").count > 12 { return false }
        let asks = ["plan ", "what ", "when ", "how ", "why ", "show ", "tell ",
                    "move ", "reschedule ", "summarise ", "summarize ", "check ",
                    "帮我", "看看", "整理", "安排", "什么", "怎么"]
        let lowered = text.lowercased()
        return !asks.contains { lowered.hasPrefix($0) || lowered.contains($0) }
    }

    // MARK: - The cat

    private var face: some View {
        ZStack {
            CatFace(mood: status.mood, isAnimating: !isOpen && presence.isAtDesk)

            if status.openToday > 0 {
                Text("\(status.openToday)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.55), in: Capsule())
                    .offset(x: 24, y: 24)
            }
        }
        .frame(width: PetArt.side, height: PetArt.side)
        // Only when there is nothing better. Scaling the whole animal is the
        // cheap way to fake life and it reads as exactly that — a drawn cat
        // moves the part a cat moves, which is its tail.
        .scaleEffect(hasAnimation ? 1.0 : (breathing ? 1.05 : 1.0))
        .contentShape(Circle())
        .onHover { isOverFace = $0; setOpen() }
        .onTapGesture { isPinned.toggle(); setOpen() }
    }

    // MARK: - The day

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(status.headline)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                // Only "stop", and only when something is running. "Start" was
                // here too and had nothing to start on an empty day — a control
                // that does nothing teaches you not to trust the others.
                // Starting belongs on the row, where the task is named.
                if model.isTimingAnything {
                    Button("Stop") { model.stopAllTimers() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                if isPinned || isThinking {
                    // Visible while thinking too: a long run is exactly when
                    // somebody needs the corner of their screen back.
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
                                   listHeight))
            }

            Divider()

            if !prompts.isEmpty {
                // Buttons rather than features: what is worth asking depends on
                // what somebody has connected, so the app ships the way to ask.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(prompts) { saved in
                            Button(saved.title) { ask(saved.prompt, title: saved.title) }
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
                // Before the prose. A plan explained in a paragraph has to be
                // read and believed; the same plan as a list of blocks with
                // times can be checked at a glance — and these are the actual
                // staged changes rather than a retelling of them.
                if let proposal = session.proposal, !proposal.isEmpty {
                    review(proposal)
                }

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
                            submit(text)
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

    /// What was actually staged, and the two buttons that decide its fate.
    ///
    /// This is the half that was missing: it planned the evening and nothing
    /// reached the task list, because the only place a proposal could be
    /// accepted was the main window. Being told a plan and having no way to say
    /// yes to it from where you were told is not a plan, it is a description.
    private func review(_ proposal: Proposal) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack {
                Text("Proposed")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Discard") { session.discardProposal() }
                    .buttonStyle(.link)
                    .font(.caption2)
                Button("Accept") { session.applyProposal() }
                    .buttonStyle(.link)
                    .font(.caption2.weight(.semibold))
                    .disabled(proposal.applicableChanges.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.top, 7)

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(proposal.changes) { reviewed in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if reviewed.isApplicable {
                                Toggle(isOn: Binding(
                                    get: { reviewed.isAccepted },
                                    set: { session.setAccepted($0, for: reviewed.id) }
                                )) { EmptyView() }
                                    .toggleStyle(.checkbox)
                                    .labelsHidden()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }

                            VStack(alignment: .leading, spacing: 1) {
                                Text(reviewed.summary)
                                    .font(.caption)
                                    .strikethrough(!reviewed.isApplicable)
                                if let detail = reviewed.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if let rejection = reviewed.rejection {
                                    Text(rejection)
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 150)
        }
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
                                MarkdownText(source: message.text)
                                    .foregroundStyle(message.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                                    .textSelection(.enabled)
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

            timerButton(line)

            if let running = elapsedMinutes(line) {
                // The clock replaces the scheduled time while it runs: what
                // time this was meant to start stops being the useful number
                // the moment it actually has.
                Text("\(running)m")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(.red)
            } else if line.daysLate > 0 {
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
        .onHover { hovered = $0 ? line.id : (hovered == line.id ? nil : hovered) }
    }

    /// Start and stop, on the task itself.
    ///
    /// Shown on hover so eight rows are not eight play buttons, and always once
    /// running — a timer you can only stop by finding it again is how an
    /// overnight session happens. The width is reserved either way, so nothing
    /// shifts under the pointer as it appears.
    private func timerButton(_ line: PetStatus.Line) -> some View {
        let running = model.isTiming(line.id)
        let show = line.kind == .task && !line.isDone && (running || hovered == line.id)
        return Group {
            if show {
                Button { model.toggleTimer(for: line.id) } label: {
                    Image(systemName: running ? "stop.circle.fill" : "play.circle")
                        .foregroundStyle(running ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .help(running ? "Stop timing" : "Start timing")
            }
        }
        .font(.caption)
        .frame(width: 14)
    }

    private func elapsedMinutes(_ line: PetStatus.Line) -> Int? {
        guard let entry = model.runningEntries.first(where: { $0.taskID == line.id })
        else { return nil }
        return max(0, Int(now.timeIntervalSince(entry.startedAt) / 60))
    }

    /// The first line of an answer that arrived while the panel was shut, and
    /// nothing more — the rest is one click away, and a bubble that quotes a
    /// paragraph at somebody who is working is the interruption this avoids.
    private func unreadBubble(_ text: String) -> some View {
        let firstLine = text
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? text

        return VStack(alignment: .leading, spacing: 4) {
            Text(firstLine)
                .font(.caption)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Click to read")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 220, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .contentShape(Rectangle())
        .onTapGesture { isPinned = true; setOpen() }
    }

    private func announcementBubble(_ title: String?, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                if let title {
                    Text(title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                Button("Dismiss") { scheduled.dismiss() }
                    .buttonStyle(.link)
                    .font(.caption2)
            }
            MarkdownText(source: text)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 240, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }

    private func nudgeBubble(_ nudge: PetNudge) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(nudge.message ?? "")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                switch nudge {
                case .water:
                    Button("Had one") { presence.noteWater() }
                case .move, .none:
                    // Standing up clears itself once they are actually away —
                    // this is for saying "not now" without getting up.
                    Button("Later") { presence.noteNudged() }
                }
            }
            .buttonStyle(.link)
            .font(.caption2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .frame(maxWidth: 220, alignment: .trailing)
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

/// The cat: an animation if one was supplied, a still if not, and the system's
/// cat emoji if neither.
///
/// Drawing the cat out of shapes was tried first and it looked assembled,
/// because it was. The emoji that replaced it is a real illustration and ships
/// at every size, but it is unmistakably an emoji rather than *this app's*
/// character — so artwork wins whenever there is any, and the emoji is what
/// keeps a build with a missing asset running rather than blank.
///
/// The emoji is framed differently on purpose. A drawn cat is a whole animal
/// with its own colour and its own ground shadow, so it stands on the desktop
/// unaided; an emoji face is a small dark glyph that vanishes against a dark
/// wallpaper, so it keeps the tinted disc behind it. The disc used to carry the
/// mood at a distance — the poses carry it now, which is why asleep, at a desk
/// and turned-away are five silhouettes rather than five tints of one.
private struct CatFace: View {
    let mood: PetStatus.Mood
    /// Whether motion is wanted at all right now. False while the panel is up —
    /// nothing should be moving under text somebody is reading — and false at
    /// an empty desk, which is most of the day.
    var isAnimating: Bool

    var body: some View {
        if let animation = CatArtwork.animation(named: mood.assetName) {
            AnimatedCat(animation: animation, isPlaying: isAnimating)
                .frame(width: PetArt.side, height: PetArt.side)
                .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
        } else if let still = NSImage(named: mood.assetName) {
            Image(nsImage: still)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: PetArt.side, height: PetArt.side)
                .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
        } else {
            ZStack {
                Circle()
                    .fill(mood.tint.opacity(0.22))
                    .frame(width: 56, height: 56)
                    .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                Text(mood.cat).font(.system(size: 40))
            }
        }
    }
}

/// Plays a decoded loop, one frame at a time, and stops dead when it is not
/// wanted.
///
/// Deliberately not `NSImageView.animates`: that plays forever from the moment
/// it is on screen, and this is a window that sits on the desktop all day. The
/// loop here is a `Task` that can be cancelled, so "not playing" costs exactly
/// nothing rather than costing less.
private struct AnimatedCat: View {
    let animation: CatArtwork.Animation
    let isPlaying: Bool

    @State private var index = 0

    var body: some View {
        Image(nsImage: animation.frames[min(index, animation.count - 1)])
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            // Restarted whenever playing changes, and cancelled with the view.
            .task(id: isPlaying) {
                guard isPlaying else { return }
                while !Task.isCancelled {
                    let hold = animation.delay(at: index)
                    try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    index = (index + 1) % animation.count
                }
            }
    }
}

enum PetArt {
    /// Big enough to read a pose at a glance, small enough not to be furniture.
    static let side: CGFloat = 72
}

extension PetStatus.Mood {
    var assetName: String {
        switch self {
        case .idle: "cat-idle"
        case .working: "cat-working"
        case .restDue: "cat-rest"
        case .behind: "cat-behind"
        case .clear: "cat-clear"
        }
    }

    /// Nine cat faces ship with the system, which is more expressions than the
    /// app has moods — and they are properly drawn, in colour, at every size,
    /// with no licence attached to anything downloaded from anywhere.
    ///
    /// Drawing one by hand was the alternative and it showed: shapes assembled
    /// into a cat look assembled. This is the same trade as not writing a
    /// markdown parser — the platform already has one, and better.
    var cat: String {
        switch self {
        case .idle: "🐱"
        case .working: "😼"
        case .restDue: "😽"
        case .behind: "😿"
        case .clear: "😸"
        }
    }

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
