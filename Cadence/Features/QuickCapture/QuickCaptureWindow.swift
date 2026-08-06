import AppKit
import SwiftUI

/// The Spotlight-style capture panel. Owns its own `NSPanel` so it can float
/// above other apps and disappear as soon as it loses focus.
@MainActor
final class QuickCaptureController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(CGPoint(
                x: frame.midX - size.width / 2,
                y: frame.midY + frame.height * 0.15
            ))
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 92),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self

        let root = QuickCaptureView(
            onSubmit: { [weak self] parsed in
                self?.commit(parsed)
            },
            onCancel: { [weak self] in self?.hide() }
        )
        .environment(model)

        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }

    private func commit(_ parsed: ParsedCapture) {
        guard !parsed.isEmpty else { return }
        let projectID = parsed.projectName.flatMap { name in
            model.projects.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }?.id
                ?? model.projects.first { $0.name.localizedCaseInsensitiveContains(name) }?.id
        }
        model.createTodo(
            title: parsed.title,
            projectID: projectID,
            tagNames: parsed.tagNames,
            priority: parsed.priority,
            estimateMinutes: parsed.estimateMinutes,
            dueAt: parsed.dueAt,
            scheduledAt: parsed.scheduledAt
        )
        hide()
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}

// MARK: - View

struct QuickCaptureView: View {
    var onSubmit: (ParsedCapture) -> Void
    var onCancel: () -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var parsed: ParsedCapture { CaptureParser.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                TextField("What needs doing?", text: $text)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($isFocused)
                    .onSubmit {
                        onSubmit(parsed)
                        text = ""
                    }
            }

            HStack(spacing: 6) {
                if parsed.summaryChips.isEmpty {
                    Text("#tag  @project  !1-3  ~45m  tomorrow 3pm")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(parsed.summaryChips, id: \.self) { chip in
                        Text(chip)
                            .font(.caption)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            .frame(height: 18)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(.ultraThinMaterial)
        .onAppear { isFocused = true }
        .onExitCommand(perform: onCancel)
    }
}
