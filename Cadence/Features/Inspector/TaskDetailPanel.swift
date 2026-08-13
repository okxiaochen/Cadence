import AppKit
import SwiftUI

/// The task detail as a floating utility panel rather than a sidebar column.
///
/// A panel rather than a popover on purpose: detail can be opened from a list
/// row *or* a calendar block, and a block's task is often not in the current
/// list at all — so there is no reliable view to anchor a popover to.
@MainActor
final class TaskDetailPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let model: AppModel
    private let session: AgentSession
    private let preferences: Preferences

    init(model: AppModel, session: AgentSession, preferences: Preferences) {
        self.model = model
        self.session = session
        self.preferences = preferences
    }

    /// The task the panel is currently placed for, so it follows you to the
    /// next task you click instead of staying where the first one was.
    private var placedForID: String?

    func sync() {
        if model.inspectedID == nil { hide() } else { show() }
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel

        applyAppearance(to: panel)
        if !panel.isVisible || placedForID != model.inspectedID {
            place(panel)
            placedForID = model.inspectedID
        }
        panel.orderFront(nil)
    }

    /// The window half of the background setting.
    ///
    /// The SwiftUI side paints the material and the wash; a material can only
    /// see through to the desktop if the *window* is non-opaque, and a panel is
    /// opaque with a solid `windowBackgroundColor` until told otherwise. Done
    /// here as well as in `windowBackground` so the panel is right in its first
    /// frame rather than flashing grey and then settling.
    private func applyAppearance(to panel: NSPanel) {
        let appearance = preferences.background
        panel.isOpaque = !appearance.isTranslucent
        panel.backgroundColor = appearance.isTranslucent ? .clear : .windowBackgroundColor
        // Never pin `appearance`: inheriting is what keeps light and dark
        // working when the system switches underneath us.
        panel.appearance = nil
    }

    /// Opens beside whatever was clicked.
    ///
    /// The pointer is the anchor, not the row: detail opens from a list row, a
    /// calendar block, a session bar and the menu bar, and threading a screen
    /// rect out of each of those means a `GeometryReader` per row for a value
    /// that is stale the moment the list scrolls. The click that opened the
    /// panel happened at the pointer, so the pointer *is* where the task is.
    private func place(_ panel: NSPanel) {
        let size = panel.frame.size
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let gap: CGFloat = 16
        // To the right of the pointer, unless it would hang off the screen.
        var x = pointer.x + gap
        if x + size.width > visible.maxX {
            x = pointer.x - gap - size.width
        }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)

        // Roughly centred on the pointer, then pushed back inside the screen.
        var top = pointer.y + size.height / 3
        top = min(max(top, visible.minY + size.height + 8), visible.maxY - 8)

        panel.setFrameTopLeftPoint(CGPoint(x: x, y: top))
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 540),
            styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Details"
        panel.titlebarAppearsTransparent = true
        // The task's own title field is the heading; a titlebar saying
        // "Details" above it is the same thing said twice.
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.delegate = self

        let root = TaskDetailPanelView()
            .environment(model)
            .environment(session)
            .environment(preferences)

        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }

    func windowWillClose(_ notification: Notification) {
        model.inspectedID = nil
    }
}

/// Follows `inspectedID`, so the panel updates when you click a different task
/// instead of needing to be reopened.
struct TaskDetailPanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences

    var body: some View {
        Group {
            if let detail = model.inspectedDetail {
                TaskDetailView(detail: detail)
                    .id(detail.id)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("No task selected").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 340, minHeight: 420)
        // The same treatment the main window gets, from the same setting, so
        // the panel is part of the app rather than a stock grey utility box.
        // `windowBackground` reaches the panel itself and makes it non-opaque,
        // which is what lets `.behindWindow` blending see anything at all.
        .windowBackground(preferences.background)
    }
}
