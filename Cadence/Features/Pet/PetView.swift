import SwiftUI

/// The companion itself: a small face that sits on the desktop, and a panel
/// that appears when you point at it.
///
/// **Nothing here animates while it is idle.** A single circle breathing with
/// `repeatForever` was measured at 17–19% of a core, continuously; the same
/// circle held still costs 0.0%. The window is free, the animation is not — so
/// movement happens on hover and on a change of mood, and never on a loop.
struct PetView: View {
    var status: PetStatus
    var onOpen: () -> Void
    var onCapture: () -> Void
    var onToggleTimer: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if isHovering {
                details
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if status.wantsAttention {
                // Unprompted, so it earns its place: only when something is
                // wrong or about to start.
                bubble(status.headline)
                    .transition(.opacity)
            }

            face
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(10)
        .animation(.snappy(duration: 0.18), value: isHovering)
        .animation(.snappy(duration: 0.25), value: status.mood)
        .onHover { isHovering = $0 }
    }

    // MARK: - The face

    private var face: some View {
        ZStack {
            Circle()
                .fill(status.mood.tint.gradient)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)

            // Eyes carry the mood. Cheaper than a sprite sheet, and it means
            // every state is one static frame rather than a loop.
            HStack(spacing: 11) {
                eye
                eye
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
        .contentShape(Circle())
        .onTapGesture(perform: onOpen)
    }

    @ViewBuilder
    private var eye: some View {
        switch status.mood {
        case .restDue:
            // Shut, which is the whole message.
            Capsule().fill(.black.opacity(0.75)).frame(width: 9, height: 2.5)
        case .working:
            Capsule().fill(.black.opacity(0.8)).frame(width: 7, height: 6)
        case .behind:
            Circle().fill(.black.opacity(0.8)).frame(width: 9, height: 9)
        case .clear, .idle:
            Circle().fill(.black.opacity(0.75)).frame(width: 8, height: 8)
        }
    }

    // MARK: - What hovering reveals

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(status.headline)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

            if let event = status.nextEvent, status.breakAdvice.isDue {
                // The headline is the break, so the meeting still needs saying.
                Label(
                    event.minutesAway <= 0
                        ? "\(event.title) — now"
                        : "\(event.title) in \(Format.duration(event.minutesAway))",
                    systemImage: "calendar"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // Only when the headline is about something else. Otherwise the
            // count is stated twice in four lines, which is the habit this
            // app's design notes single out by name.
            if status.openToday > 0, !status.headlineIsAboutOpenWork {
                Label(
                    status.openToday == 1 ? "1 open today" : "\(status.openToday) open today",
                    systemImage: "circle.dashed"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 10) {
                Button("Open", action: onOpen)
                Button("Add", action: onCapture)
                Button(status.timingMinutes == nil ? "Start" : "Stop", action: onToggleTimer)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
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
    /// Whether the headline already accounts for the open count, so the panel
    /// does not repeat it underneath.
    var headlineIsAboutOpenWork: Bool {
        if breakAdvice.isDue || nextEvent != nil || timingMinutes != nil { return false }
        switch focus {
        case .overdue, .empty: return true
        case .underway, .next, .allDone: return false
        }
    }

    /// Whether it should say something without being asked. Deliberately narrow:
    /// an idle day is not news, and a companion that comments on nothing in
    /// particular is one you stop reading.
    var wantsAttention: Bool {
        if breakAdvice.isDue { return true }
        if let event = nextEvent, event.minutesAway <= 10 { return true }
        return false
    }
}
