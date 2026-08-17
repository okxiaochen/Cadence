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
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func setVisible(_ visible: Bool) {
        visible ? show() : hide()
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

    /// Built once. Everything it shows it reads from the model itself, so
    /// there is nothing to rebuild — and nothing to lose when it changes. The
    /// first version replaced this view on every refresh, which threw away the
    /// pin, the hover and any half-typed line once a minute.
    private func hosting() -> NSHostingView<PetView> {
        let view = PetView(
            model: model,
            preferences: preferences,
            session: session,
            onOpen: { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.openMainWindow()
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

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        preferences.petWindowOrigin = panel.frame.origin
    }
}
