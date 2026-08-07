import SwiftUI

@main
struct CadenceApp: App {
    @State private var model: AppModel
    @State private var quickCapture: QuickCaptureController
    @State private var preferences = Preferences.shared
    @State private var session: AgentSession
    @State private var updater: Updater
    @State private var notifications: NotificationService
    @State private var startupError: String?

    @AppStorage("workspaceMode") private var mode: WorkspaceMode = .list

    /// `@AppStorage` rather than a Binding built from Preferences: a computed
    /// property hands `MenuBarExtra` a freshly constructed Binding on every
    /// Scene evaluation, which SwiftUI reads as a change and re-evaluates, and
    /// the app spins at 100% CPU. This projected binding is stable.
    @AppStorage("showsMenuBarItem") private var showsMenuBarItem = true

    init() {
        let database: AppDatabase
        var failure: String?
        do {
            database = try AppDatabase.onDisk()
        } catch {
            // Never lose the session to a bad file: run in memory and say so.
            failure = "Could not open the database (\(error.localizedDescription)). "
                + "Running in memory — changes will not be saved."
            database = try! AppDatabase.inMemory()
        }

        let model = AppModel(database: database)
        _model = State(initialValue: model)
        _quickCapture = State(initialValue: QuickCaptureController(model: model))
        _session = State(initialValue: AgentSession(model: model))
        _updater = State(initialValue: Updater(database: database))
        _notifications = State(initialValue: NotificationService(model: model))
        _startupError = State(initialValue: failure)
    }

    var body: some Scene {
        Window("Cadence", id: "main") {
            RootView()
                .environment(model)
                .environment(preferences)
                .environment(session)
                .environment(updater)
                .environment(notifications)
                .task {
                    if let startupError { model.errorMessage = startupError }
                    await notifications.refreshAuthorization()
                    await updater.checkInBackground()
                    GlobalHotkey.shared.onFire = { [quickCapture] in
                        Task { @MainActor in quickCapture.toggle() }
                    }
                    GlobalHotkey.shared.register()
                }
        }
        .defaultSize(width: 1200, height: 760)
        .commands { commands }

        MenuBarExtra(isInserted: $showsMenuBarItem) {
            MenuBarView()
                .environment(model)
                .environment(preferences)
        } label: {
            // Icon plus a count, not the next task's title: a label whose width
            // changes every few minutes shoves every other status item sideways.
            // Two digits is a bounded, and therefore tolerable, amount of drift.
            Image(systemName: "calendar.day.timeline.left")
            Text(model.todayCountLabel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .environment(preferences)
                .environment(session)
                .environment(updater)
                .environment(notifications)
        }
    }

    @CommandsBuilder
    private var commands: some Commands {
        CommandGroup(after: .newItem) {
            Button("Quick Capture") { quickCapture.show() }
                .keyboardShortcut(.space, modifiers: .option)
        }

        CommandGroup(before: .toolbar) {
            Picker("View", selection: $mode) {
                Text("List").tag(WorkspaceMode.list)
                Text("Calendar").tag(WorkspaceMode.calendar)
                Text("Split").tag(WorkspaceMode.split)
            }
            .pickerStyle(.inline)

            Divider()
        }

        CommandMenu("Task") {
            Button("Complete") {
                model.setStatus(.done, for: Array(model.selection))
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.selection.isEmpty)

            Button("Show Details") {
                model.inspectedID = model.selection.first
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(model.selection.count != 1)

            Button("Add Subtask") {
                if let id = model.selection.first { model.addSubtask(to: id) }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(model.selection.count != 1)

            Divider()

            Button("Delete", role: .destructive) {
                model.delete(ids: Array(model.selection))
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(model.selection.isEmpty)
        }

        CommandMenu("Calendar") {
            Button("Day") { model.calendarScale = .day }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("3 Days") { model.calendarScale = .threeDay }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button("Week") { model.calendarScale = .week }
                .keyboardShortcut("3", modifiers: [.command, .option])

            Divider()

            Button("Today") { model.goToToday() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Previous") { model.stepCalendar(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: .option)
            Button("Next") { model.stepCalendar(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: .option)

            Divider()

            Button("Unschedule Selected Block") {
                if let id = model.selectedBlockID { model.deleteBlock(id) }
            }
            .disabled(model.selectedBlockID == nil)
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                Task { await updater.checkNow() }
            }
            .disabled(updater.state.isBusy)
        }

        CommandGroup(replacing: .help) {}
    }
}
