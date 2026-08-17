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
struct PetView: View {
    var status: PetStatus
    var onOpen: () -> Void
    var onToggleTimer: () -> Void
    var onToggleDone: (String) -> Void
    /// Whatever was typed at it. Returning false means it was not understood,
    /// so the field keeps the text rather than swallowing it.
    var onSubmit: (String) -> Bool

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
        let wanted = isOverFace || isOverPanel || isPinned || isTyping
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
        .task { await breathe() }
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

    // MARK: - The face

    private var face: some View {
        ZStack {
            Circle()
                .fill(status.mood.tint.gradient)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)

            VStack(spacing: 5) {
                HStack(spacing: 11) { eye; eye }
                mouth
            }
            .offset(y: -1)

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
                Button(status.timingMinutes == nil ? "Start" : "Stop", action: onToggleTimer)
                    .buttonStyle(.link)
                    .font(.caption)
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
                .frame(height: min(CGFloat(status.today.count) * 30 + 8, 240))
            }

            Divider()

            // The way in for everything this does not do yet. Today it captures;
            // the field is the part that has to exist for anything else to be
            // reachable from here.
            HStack(spacing: 6) {
                Image(systemName: "plus.circle").foregroundStyle(.secondary)
                TextField("Add a task…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .focused($isTyping)
                    .onSubmit {
                        if onSubmit(draft) { draft = "" }
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .frame(width: 268, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private func row(_ line: PetStatus.Line) -> some View {
        HStack(spacing: 7) {
            switch line.kind {
            case .task:
                Button { onToggleDone(line.id) } label: {
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
        return false
    }
}
