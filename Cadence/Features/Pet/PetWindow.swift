import AppKit
import SwiftUI

/// The panel the companion lives in.
///
/// Every flag here was checked against a running window before it was written
/// down, because the failure modes are all invisible until you try: a panel
/// that steals focus makes you lose your place mid-sentence, one that does not
/// join every Space vanishes when you switch desktops, and one that is opaque
/// is a grey square sitting on the wallpaper.
///
/// Nearly the opposite of `QuickCaptureController`'s panel, which is titled,
/// transient and hides the moment it loses focus. This one has no title, joins
/// every Space, and stays.
/// A borderless panel cannot become key, and a panel that cannot become key
/// cannot be typed into. Overriding it is what lets the companion take a line
/// of text; `.nonactivatingPanel` is what stops taking it from also yanking the
/// whole app in front of whatever you were working in.
private final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PetWindowController: NSObject, NSWindowDelegate {

    private var panel: NSPanel?
    private let model: AppModel
    private let preferences: Preferences
    /// The same session the chat panel and the unattended runs use, so two
    /// requests can never fight over the one CLI process.
    private let session: AgentSession
    private var clockTask: Task<Void, Never>?
    private var replyTask: Task<Void, Never>?
    /// The assistant's last answer, kept until the next question replaces it.
    private var lastReply: String?

    init(model: AppModel, preferences: Preferences, session: AgentSession) {
        self.model = model
        self.preferences = preferences
        self.session = session
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
        startClock()
    }

    func hide() {
        clockTask?.cancel()
        clockTask = nil
        panel?.orderOut(nil)
    }

    func setVisible(_ visible: Bool) {
        visible ? show() : hide()
    }

    // MARK: - Keeping it current

    /// A minute is enough. The companion counts in minutes, so a faster tick
    /// would redraw for nothing — and redrawing for nothing is exactly what
    /// made the first prototype cost a fifth of a core.
    private func startClock() {
        guard clockTask == nil else { return }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    private func refresh() {
        guard let panel, panel.isVisible else { return }
        panel.contentView = hosting()
    }

    // MARK: - The panel

    private func makePanel() -> NSPanel {
        let panel = PetPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 420),
            // `.nonactivatingPanel` is what lets it be clicked without pulling
            // focus off whatever you were typing in.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // `.stationary` keeps it put when Mission Control shuffles things;
        // `.ignoresCycle` keeps it out of Cmd-`.
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle
        ]
        panel.delegate = self
        panel.contentView = hosting()
        place(panel)
        return panel
    }

    private func hosting() -> NSHostingView<PetView> {
        let status = model.petStatus(breakAfterMinutes: preferences.breakAfterMinutes)
        // Noted when shown rather than when dismissed: by the time anyone
        // dismisses it, the interruption has already happened.
        if status.breakAdvice.isDue { model.noteBreakSuggested() }

        let view = PetView(
            status: status,
            onOpen: { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.openMainWindow()
            },
            onToggleTimer: { [weak self] in self?.toggleTimer() },
            onOpened: { [weak self] in self?.model.noteEventAnswered() },
            onToggleDone: { [weak self] id in
                self?.model.toggleCompleted(id)
                self?.refresh()
            },
            prompts: preferences.petPrompts.filter(\.isUsable),
            onAsk: { [weak self] text in self?.handle(text) },
            isThinking: session.status.isRunning,
            lastReply: lastReply
        )
        let hosting = NSHostingView(rootView: view)
        hosting.autoresizingMask = [.width, .height]
        return hosting
    }

    /// Bottom-right of the screen the mouse is on, out of the way of most
    /// windows' content. Remembered once moved.
    private func place(_ panel: NSPanel) {
        if let saved = preferences.petWindowOrigin {
            panel.setFrameOrigin(saved)
            return
        }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.maxX - 300, y: frame.minY + 40))
    }

    private func openMainWindow() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
    }

    /// One line in, two possible meanings.
    ///
    /// Anything that reads as a task becomes one immediately — capture should
    /// not cost a model call or thirty seconds of waiting. Everything else goes
    /// to the assistant. Asking the user to pick which they meant would be
    /// asking them to know how the thing works.
    private func handle(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if Self.looksLikeATask(trimmed) {
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
                lastReply = "Added “\(parsed.title)”."
                refresh()
                return
            }
        }

        lastReply = nil
        session.send(trimmed, surface: .chat)
        observeSession()
        refresh()
    }

    /// A question ends in a question mark, or asks for something to be done.
    /// A task is a noun phrase. This is a heuristic and it is allowed to be
    /// wrong: getting it wrong makes a task instead of an answer, which is
    /// visible and one click to undo.
    static func looksLikeATask(_ text: String) -> Bool {
        if text.hasSuffix("?") || text.hasSuffix("？") { return false }
        // A saved prompt is a sentence; a captured task rarely is.
        if text.split(separator: " ").count > 12 { return false }
        let asks = ["plan ", "what ", "when ", "how ", "why ", "show ", "tell ",
                    "move ", "reschedule ", "summarise ", "summarize ", "check ",
                    "帮我", "看看", "整理", "安排", "什么", "怎么"]
        let lowered = text.lowercased()
        return !asks.contains { lowered.hasPrefix($0) || lowered.contains($0) }
    }

    /// Watches the shared session so the panel can stop saying "thinking" and
    /// show what came back. Polled rather than observed: the panel is rebuilt
    /// wholesale on each refresh, so there is no view to invalidate.
    private func observeSession() {
        replyTask?.cancel()
        replyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let self, !Task.isCancelled else { return }
                if !session.status.isRunning {
                    lastReply = session.messages.last { $0.role == .assistant }?.text
                    refresh()
                    return
                }
                refresh()
            }
        }
    }

    private func toggleTimer() {
        if let running = model.runningEntries.first {
            model.stopTimer(for: running.taskID)
        } else if case .underway(let item) = model.agendaFocus() {
            model.toggleTimer(for: item.todo.id)
        } else if case .next(let item) = model.agendaFocus() {
            model.toggleTimer(for: item.todo.id)
        }
        refresh()
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        preferences.petWindowOrigin = panel.frame.origin
    }
}
