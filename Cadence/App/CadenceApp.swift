import SwiftUI

@main
struct CadenceApp: App {
    @State private var model: AppModel
    @State private var quickCapture: QuickCaptureController
    @State private var pet: PetWindowController
    @State private var preferences = Preferences.shared
    @State private var session: AgentSession
    @State private var updater: Updater
    @State private var notifications: NotificationService
    @State private var externalAgents: ExternalAgentService
    @State private var scheduledRuns: ScheduledRuns
    @State private var startupError: String?

    @AppStorage("workspaceMode") private var mode: WorkspaceMode = .list

    /// `@AppStorage` rather than a Binding built from Preferences: a computed
    /// property hands `MenuBarExtra` a freshly constructed Binding on every
    /// Scene evaluation, which SwiftUI reads as a change and re-evaluates, and
    /// the app spins at 100% CPU. This projected binding is stable.
    @AppStorage("showsMenuBarItem") private var showsMenuBarItem = true

    /// Available in `App` scope, which is what lets a menu command open a
    /// window without routing through a view.
    @Environment(\.openWindow) private var openWindow

    private func openReportWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "report")
    }

    init() {
        // Overlay scrollers rather than the legacy kind with a slot.
        //
        // `NSScroller` draws that slot itself, opaque and near-white, so no
        // amount of hiding a scroll view's background reaches it — and over a
        // window you can see through it reads as a bright bar laid on the blur.
        // Which style you get otherwise depends on the input device: a trackpad
        // gets overlay, a mouse gets legacy.
        //
        // Setting `scrollerStyle` on each `NSScrollView` was tried first and
        // does not hold. The property reads back as overlay and the layout
        // stays legacy, because SwiftUI reassigns it from the system preference
        // afterwards. This changes what the system preference *is* for this
        // process, so there is nothing to be reassigned from.
        //
        // Registered rather than set: the registration domain sits below the
        // user's own, so somebody who has explicitly asked for scrollbars that
        // are always visible still gets them. Ours is only the default.
        UserDefaults.standard.register(defaults: ["AppleShowScrollBars": "WhenScrolling"])

        let database: AppDatabase
        var failure: String?
        do {
            database = try AppDatabase.onDisk()
            if database.repairedOrphanRows > 0 {
                // Quiet repairs are how a database ends up mysteriously
                // different. Say it once, plainly.
                failure = "Repaired \(database.repairedOrphanRows) leftover "
                    + "\(database.repairedOrphanRows == 1 ? "row" : "rows") from a task "
                    + "that had been deleted outside Cadence. Your tasks are unaffected."
            }
        } catch {
            // Never lose the session to a bad file: run in memory and say so.
            failure = "Could not open the database (\(error.localizedDescription)). "
                + "Running in memory — changes will not be saved."
            database = try! AppDatabase.inMemory()
        }

        let model = AppModel(database: database)
        _model = State(initialValue: model)
        _quickCapture = State(initialValue: QuickCaptureController(model: model))


        _updater = State(initialValue: Updater(database: database))
        _notifications = State(initialValue: NotificationService(model: model))
        _externalAgents = State(initialValue: ExternalAgentService(model: model))
        // One session, shared: the unattended runs go through the same agent
        // as the chat panel, so two runs can never fight over the CLI.
        let session = AgentSession(model: model)
        _session = State(initialValue: session)
        _scheduledRuns = State(initialValue: ScheduledRuns(model: model, session: session))
        _pet = State(initialValue: PetWindowController(
            model: model, preferences: .shared, session: session
        ))
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
                    preferences.appAppearance.apply()
                    if let startupError { model.errorMessage = startupError }
                    await notifications.refreshAuthorization()
                    await updater.checkInBackground()
                    externalAgents.startIfEnabled()
                    scheduledRuns.start()
                    pet.setVisible(preferences.showsDesktopPet)
                    GlobalHotkey.shared.register(.quickCapture) { [quickCapture] in
                        Task { @MainActor in quickCapture.toggle() }
                    }
                    // ⌥⇧Space: start or stop the clock without leaving
                    // whatever you are actually working in.
                    GlobalHotkey.shared.register(
                        .toggleTimer,
                        modifiers: GlobalHotkey.Modifiers.optionShift
                    ) { [model] in
                        Task { @MainActor in model.toggleTimerForFocusedTask() }
                    }
                }
                .onChange(of: preferences.showsDesktopPet) { _, shows in
                    pet.setVisible(shows)
                }
                // `cadence://…` from a script, a launcher or a git hook.
                .onOpenURL { url in
                    URLCommandHandler.handle(url, model: model) { openWindow(id: $0) }
                }
        }
        .defaultSize(width: 1200, height: 760)
        .commands { commands }

        // Its own window rather than a fourth workspace mode: this is something
        // you open on a Friday and close again, not a way of working.
        Window("Time Report", id: "report") {
            TimeReportView()
                .environment(model)
                .environment(preferences)
        }
        .defaultSize(width: 520, height: 620)

        MenuBarExtra(isInserted: $showsMenuBarItem) {
            MenuBarView()
                .environment(model)
                .environment(preferences)
        } label: {
            // Icon plus a count, not the next task's title: a label whose width
            // changes every few minutes shoves every other status item sideways.
            // Two digits is a bounded, and therefore tolerable, amount of drift.
            Image(systemName: model.menuBarSymbol)
            Text(model.menuBarLabel(includingOverdue: preferences.showsOverdue))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .environment(externalAgents)
                .environment(scheduledRuns)
                .environment(preferences)
                .environment(session)
                .environment(updater)
                .environment(notifications)
        }
    }

    @CommandsBuilder
    private var commands: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Task") {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .focusComposer, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Quick Capture") { quickCapture.show() }
                .keyboardShortcut(.space, modifiers: .option)
        }

        CommandGroup(before: .toolbar) {
            Button("Time Report") { openReportWindow() }
                .keyboardShortcut("r", modifiers: [.command, .shift])

            Divider()

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
