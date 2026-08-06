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

    func sync() {
        if model.inspectedID == nil { hide() } else { show() }
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        guard !panel.isVisible else { return }

        // Open beside the main window rather than on top of it.
        if let main = NSApp.mainWindow {
            let frame = main.frame
            panel.setFrameTopLeftPoint(CGPoint(
                x: min(frame.maxX - 40, frame.maxX - panel.frame.width - 24),
                y: frame.maxY - 60
            ))
        }
        panel.orderFront(nil)
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
    }
}
