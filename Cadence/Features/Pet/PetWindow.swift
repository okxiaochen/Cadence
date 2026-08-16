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
    private var clockTask: Task<Void, Never>?

    init(model: AppModel, preferences: Preferences) {
        self.model = model
        self.preferences = preferences
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
            onToggleDone: { [weak self] id in
                self?.model.toggleCompleted(id)
                self?.refresh()
            },
            onSubmit: { [weak self] text in
                self?.capture(text) ?? false
            }
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

    /// Same parser the quick-capture panel uses, so `#tag !2 ~45m tomorrow`
    /// means the same thing typed at the companion as typed anywhere else.
    private func capture(_ text: String) -> Bool {
        let parsed = CaptureParser.parse(text)
        guard !parsed.isEmpty else { return false }
        model.createTodo(
            title: parsed.title,
            tagNames: parsed.tagNames,
            priority: parsed.priority,
            estimateMinutes: parsed.estimateMinutes,
            dueAt: parsed.dueAt,
            scheduledAt: parsed.scheduledAt
        )
        refresh()
        return true
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
