import AppKit
import Foundation

/// `cadence://` — the scripting entry point.
///
/// This is for humans and their launchers: a Raycast script, a shell alias, a
/// git hook. Agents should use the MCP endpoint instead (`ExternalAgentService`),
/// which is a real protocol with structured results; a URL can only fire and
/// forget, and cannot answer a question.
///
/// Everything goes through the same `CaptureParser` and `AppModel` as typing
/// into the composer, so a task filed from a script is indistinguishable from
/// one filed by hand — including undo.
enum URLCommand {
    case add(String)
    case start(taskID: String?)
    case stop
    case show(taskID: String)
    case report

    /// `cadence://add?text=Fix%20the%20thing%20%23bug%20~1h%20tomorrow`
    ///
    /// The whole capture grammar works, since the text is handed to the same
    /// parser the composer uses.
    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "cadence" else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Both `cadence://add?…` and `cadence:///add?…` reach here; the host is
        // empty in the second form, which is what a shell tends to produce.
        let action = (url.host?.isEmpty == false ? url.host : url.path.replacingOccurrences(of: "/", with: ""))?
            .lowercased()

        switch action {
        case "add":
            guard let text = value("text") ?? value("title"), !text.isEmpty else { return nil }
            self = .add(text)
        case "start":
            self = .start(taskID: value("id"))
        case "stop":
            self = .stop
        case "show":
            guard let id = value("id") else { return nil }
            self = .show(taskID: id)
        case "report":
            self = .report
        default:
            return nil
        }
    }
}

@MainActor
enum URLCommandHandler {

    /// Runs a command and says whether the main window should come forward.
    /// Filing a task from a script should not steal focus; asking to see
    /// something obviously should.
    @discardableResult
    static func handle(_ url: URL, model: AppModel, openWindow: (String) -> Void) -> Bool {
        guard let command = URLCommand(url) else { return false }

        switch command {
        case .add(let text):
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
            return false

        case .start(let taskID):
            if let taskID {
                model.startTimer(for: taskID)
            } else {
                // No id: the same guess ⌥⇧Space makes.
                model.toggleTimerForFocusedTask()
            }
            return false

        case .stop:
            model.stopAllTimers()
            return false

        case .show(let taskID):
            model.inspectedID = taskID
            NSApp.activate(ignoringOtherApps: true)
            openWindow("main")
            return true

        case .report:
            NSApp.activate(ignoringOtherApps: true)
            openWindow("report")
            return true
        }
    }
}
