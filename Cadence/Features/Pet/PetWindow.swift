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
@MainActor
final class PetWindowController: NSObject, NSWindowDelegate {

    private var panel: NSPanel?
    private let model: AppModel
    private let preferences: Preferences
    /// Handed in rather than reached for: quick capture owns its own panel, and
    /// two controllers each holding a global reference to the other is how a
    /// retain cycle starts.
    private let onCapture: () -> Void
    private var clockTask: Task<Void, Never>?

    init(model: AppModel, preferences: Preferences, onCapture: @escaping () -> Void) {
        self.model = model
        self.preferences = preferences
        self.onCapture = onCapture
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
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 220),
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
            onCapture: onCapture,
            onToggleTimer: { [weak self] in self?.toggleTimer() }
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
