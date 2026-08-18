import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            PlanningSettings()
                .tabItem { Label("Planning", systemImage: "clock") }
            CalendarSettings()
                .tabItem { Label("Calendars", systemImage: "calendar") }
            AISettings()
                .tabItem { Label("AI", systemImage: "sparkles") }
            NotificationSettings()
                .tabItem { Label("Alerts", systemImage: "bell") }
            UpdateSettings()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 540, height: 420)
    }
}

private struct PlanningSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences
    @AppStorage("showsMenuBarItem") private var showsMenuBarItem = true

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section("Where I am") {
                TextField("City, district or postcode", text: $preferences.place)
                Text("Anything that needs a location uses this — weather, "
                     + "sunset, how long a journey takes. Left blank it is "
                     + "guessed from your IP address, which is your provider's "
                     + "exchange and can be an hour away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Working hours") {
                HStack {
                    Picker("From", selection: $preferences.workdayStartHour) {
                        ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) }
                    }
                    Picker("To", selection: $preferences.workdayEndHour) {
                        ForEach(1..<25, id: \.self) { Text(hourLabel($0)).tag($0) }
                    }
                }
                Toggle("Include weekends", isOn: $preferences.includesWeekends)
            }

            Section("Desktop companion") {
                Toggle("Show on the desktop", isOn: $preferences.showsDesktopPet)

                if preferences.showsDesktopPet {

                    CompanionCharacter()

                    Picker("Suggest a break after", selection: $preferences.breakAfterMinutes) {
                        ForEach([25, 40, 50, 60, 90], id: \.self) { Text("\($0)m").tag($0) }
                    }
                    Picker("Suggest standing up after", selection: $preferences.moveAfterMinutes) {
                        Text("Never").tag(0)
                        ForEach([30, 45, 50, 60, 90], id: \.self) { Text("\($0)m").tag($0) }
                    }
                    Picker("Suggest water every", selection: $preferences.waterAfterMinutes) {
                        Text("Never").tag(0)
                        ForEach([45, 60, 90, 120], id: \.self) { Text("\($0)m").tag($0) }
                    }

                    LabeledContent("Buttons") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach($preferences.petPrompts) { $saved in
                                HStack(spacing: 6) {
                                    TextField("Label", text: $saved.title)
                                        .frame(width: 90)
                                    TextField("What to ask", text: $saved.prompt)
                                    Picker("", selection: Binding(
                                        get: { saved.everyMinutes ?? 0 },
                                        set: { saved.everyMinutes = $0 == 0 ? nil : $0 }
                                    )) {
                                        Text("Button").tag(0)
                                        Text("30m").tag(30)
                                        Text("1h").tag(60)
                                        Text("2h").tag(120)
                                        Text("4h").tag(240)
                                        Text("Daily").tag(1440)
                                    }
                                    .labelsHidden()
                                    .frame(width: 78)
                                    Button {
                                        preferences.petPrompts.removeAll { $0.id == saved.id }
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                }
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                            }

                            Button("Add a button") {
                                preferences.petPrompts.append(
                                    PetPrompt(title: "", prompt: "")
                                )
                            }
                            .controlSize(.small)
                        }
                    }

                    Text("A cadence turns a button into something it checks on its "
                         + "own — weather, a share price, a feed you follow. It only "
                         + "runs while you are at the desk, and only speaks when "
                         + "there is something worth saying. Anything it has to "
                         + "fetch needs a command you have allowed under AI.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Each button sends its text to the assistant. What is "
                         + "worth asking depends on what you have connected — "
                         + "\u{201C}what did I miss today?\u{201D} means something "
                         + "different with a ticket tracker attached — so these "
                         + "are yours to write rather than a fixed list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("A small window that stays on the desktop. Point at it for "
                     + "today, or click it to open Cadence. It holds still when "
                     + "nothing is happening — an animation that never stops "
                     + "costs a fifth of a processor core, all day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Toggle("Show the agenda in the menu bar", isOn: $showsMenuBarItem)
            }

            Section("Scheduling") {
                Picker("Snap to", selection: $preferences.snapMinutes) {
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                }
                Picker("Default estimate", selection: $preferences.defaultEstimateMinutes) {
                    ForEach([15, 25, 30, 45, 60, 90], id: \.self) { Text(Format.duration($0)).tag($0) }
                }
            }

            Section("Timers") {
                Toggle(
                    "Time several tasks at once",
                    isOn: Binding(
                        get: { preferences.allowsConcurrentTimers },
                        set: { allows in
                            preferences.allowsConcurrentTimers = allows
                            // Switching to one-at-a-time with three clocks
                            // already going would leave a state the setting
                            // says is impossible.
                            if !allows { model.stopAllTimers() }
                        }
                    )
                )
                Text(preferences.allowsConcurrentTimers
                     ? "Starting a timer leaves any others running."
                     : "Starting a timer stops whatever else was running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func hourLabel(_ hour: Int) -> String {
        guard hour < 24 else { return "midnight" }
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }
}

/// Choosing who the companion is, and editing one if none of them fit.
///
/// Its own view rather than a `@ViewBuilder` on `PlanningSettings` because it
/// needs a binding into the persona being edited, and a builder called from a
/// body that has already rebound `preferences` cannot have one.
private struct CompanionCharacter: View {
    @Environment(Preferences.self) private var preferences

    /// Where the selected persona sits in the editable list, or nil when a
    /// built-in is selected. Built-ins are code and cannot be written to, so
    /// this doubles as "is there anything to show an editor for".
    private var editableIndex: Int? {
        preferences.customPersonas.firstIndex { $0.id == preferences.personaID }
    }

    var body: some View {
        @Bindable var preferences = preferences

        // A plain Form row rather than a `LabeledContent` holding its own
        // stack: inside one, the picker floats in the middle of the trailing
        // column and the caption sets ragged-left against the window edge,
        // which reads as a different kind of control from the four rows under
        // it. It is the same control, so it should sit the same way.
        Picker("Character", selection: $preferences.personaID) {
            ForEach(preferences.allPersonas) { Text($0.name).tag($0.id) }
        }

        VStack(alignment: .leading, spacing: 8) {
            // Only while choosing. The editor's own "In one line" field holds
            // the same sentence, and a caption repeating the field two rows
            // above it is the app saying one thing twice.
            if editableIndex == nil {
                Text(preferences.persona.tagline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let index = editableIndex {
                editor(for: $preferences.customPersonas[index])
            } else {
                Button("Make a copy to edit") {
                    let copy = preferences.persona.copyForEditing()
                    preferences.customPersonas.append(copy)
                    preferences.personaID = copy.id
                }
                .controlSize(.small)
            }

            Text("The character is how it speaks, not what it does — it will "
                 + "not soften a clash or round off a time to stay in voice. How "
                 + "often it speaks up unasked is part of the character too, so a "
                 + "quiet one stays quiet however many cadences you set below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func editor(for persona: Binding<Persona>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Name", text: persona.name)
                    .frame(width: 110)
                TextField("In one line", text: persona.tagline)
            }
            TextEditor(text: persona.voice)
                .font(.caption)
                .frame(height: 96)
                .scrollContentBackground(.hidden)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))

            HStack(spacing: 8) {
                Picker("Speaks up", selection: persona.dailyRemarks) {
                    Text("Never").tag(0)
                    ForEach([1, 2, 3, 4, 6, 8, 12], id: \.self) { Text("\($0)x a day").tag($0) }
                }
                .frame(width: 210)
                Spacer()
                Button("Delete") {
                    let gone = persona.wrappedValue
                    preferences.customPersonas.removeAll { $0.id == gone.id }
                    // Back to what it was copied from rather than to the first
                    // in the list: somebody who edited Sable and gave up wants
                    // Sable back, not whoever happens to sort first.
                    preferences.personaID = gone.basedOn ?? Persona.fallback.id
                }
                .controlSize(.small)
            }

            Text("Written in the second person, as instructions to it. The part "
                 + "that actually changes how it sounds is what you tell it *not* "
                 + "to do.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .font(.caption)
    }
}

private struct CalendarSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences

    var body: some View {
        Form {
            Section("Busy overlay") {
                switch model.eventKit.access {
                case .authorized:
                    if model.eventKit.sources.isEmpty {
                        Text("No calendars found.").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.eventKit.sources) { source in
                            Toggle(isOn: Binding(
                                get: { !preferences.hiddenCalendarIDs.contains(source.id) },
                                set: { shown in
                                    if shown {
                                        preferences.hiddenCalendarIDs.remove(source.id)
                                    } else {
                                        preferences.hiddenCalendarIDs.insert(source.id)
                                    }
                                    model.refreshBusyEvents()
                                }
                            )) {
                                HStack(spacing: 6) {
                                    Dot(colorHex: source.colorHex)
                                    Text(source.title)
                                }
                            }
                        }
                    }
                case .denied:
                    Text("Calendar access is denied. Enable it in System Settings › Privacy & Security › Calendars.")
                        .foregroundStyle(.secondary)
                case .unknown:
                    Button("Connect Calendar") {
                        Task {
                            await model.eventKit.requestAccess()
                            model.refreshBusyEvents()
                        }
                    }
                }
            }

            Section("Publish to Apple Calendar") {
                Toggle("Publish my blocks to a “Cadence” calendar", isOn: Binding(
                    get: { model.calendarSync.isEnabled },
                    set: { enabled in
                        model.calendarSync.isEnabled = enabled
                        if enabled { model.publishToCalendar() }
                    }
                ))
                .disabled(model.eventKit.access != .authorized)

                Text("Apple provides no way to make a calendar read-only. Cadence "
                     + "owns that calendar instead: your database is the source of "
                     + "truth, and anything you edit in Calendar.app is overwritten "
                     + "on the next sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.calendarSync.isEnabled {
                    Toggle("Also publish time I tracked", isOn: Binding(
                        get: { model.calendarSync.publishesTrackedTime },
                        set: { publishes in
                            model.calendarSync.publishesTrackedTime = publishes
                            // Turning it off sweeps the published sessions away
                            // on the same pass that stops matching them.
                            model.publishToCalendar()
                        }
                    ))

                    Text("Recorded sessions appear as “✓ Task name”, so the week in "
                         + "Calendar.app shows what happened beside what was planned. "
                         + "A running timer is not published until you stop it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("Sync Now") { model.publishToCalendar() }
                            .controlSize(.small)
                        if let synced = model.calendarSync.lastSyncedAt {
                            Text("last synced \(Format.time(synced))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove Calendar", role: .destructive) {
                            try? model.calendarSync.removeManagedCalendar()
                            model.calendarSync.isEnabled = false
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.eventKit.loadSources() }
    }
}

// MARK: - AI

private struct AISettings: View {
    @Environment(AgentSession.self) private var session
    @Environment(ExternalAgentService.self) private var externalAgents
    @Environment(ScheduledRuns.self) private var scheduledRuns
    @Environment(Preferences.self) private var preferences
    @Environment(AppModel.self) private var model

    @State private var testResult: String?
    @State private var isTesting = false
    @State private var copiedSetup = false
    @State private var allowedCommands: [ApprovedCommand] = []

    /// Grouped so a tool can be revoked whole. Revoking half of one leaves the
    /// assistant able to read some of it, which is a state nobody chose.
    private var connectors: [String] {
        var seen = Set<String>()
        return allowedCommands.map(\.connector).filter { seen.insert($0).inserted }
    }

    /// Resolved on each render rather than cached: the CLI can be installed, or
    /// its short-lived token can expire, while this window is open.
    private var meegleStatus: String {
        guard let client = try? MeegleClient() else {
            return "meegle CLI not found — npx @lark-project/meegle@latest install"
        }
        return client.isAuthenticated() ? "Signed in" : "Run `meegle auth login`"
    }

    var body: some View {
        @Bindable var session = session
        @Bindable var externalAgents = externalAgents
        @Bindable var scheduledRuns = scheduledRuns
        @Bindable var preferences = preferences

        Form {
            Section("Unattended runs") {
                Toggle("Draft tomorrow's plan each evening", isOn: $scheduledRuns.nightlyPlanEnabled)
                Toggle("Look back over the fortnight on Sundays", isOn: $scheduledRuns.weeklyReflectionEnabled)
                Toggle("Read back what I have said, every few days", isOn: $scheduledRuns.portraitEnabled)

                if scheduledRuns.nightlyPlanEnabled || scheduledRuns.weeklyReflectionEnabled
                    || scheduledRuns.portraitEnabled {
                    Picker("Run at", selection: $scheduledRuns.nightlyHour) {
                        ForEach([18, 19, 20, 21, 22, 23], id: \.self) { hour in
                            Text("\(hour):00").tag(hour)
                        }
                    }
                }

                Text("The first stages a proposal for you to review in the morning "
                     + "and never writes on its own. The other two write only to "
                     + "memory: the Sunday one learns how you work from your "
                     + "records, and the last learns what you care about from what "
                     + "you have said — it skips itself entirely when you have not "
                     + "said anything since last time. What either writes is under "
                     + "Memory, and can be corrected there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Meegle") {
                Toggle("Read my work items", isOn: $preferences.meegleEnabled)

                if preferences.meegleEnabled {
                    LabeledContent("Status") {
                        Text(meegleStatus).foregroundStyle(.secondary)
                    }
                }

                Text("Lets the assistant see the tickets assigned to you in Meegle "
                     + "(Lark Project) so a plan covers what your team is tracking, "
                     + "not only what you typed here. It reads through your own "
                     + "`meegle` CLI login, so it sees exactly what you see and "
                     + "Cadence never holds a token. Work items are only ever read; "
                     + "turning them into tasks still goes through review.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Allowed commands") {
                if allowedCommands.isEmpty {
                    Text("None yet. To read a tool Cadence has no built-in support "
                         + "for, the assistant has to ask first — you will see the "
                         + "exact command here before it runs, and it can never ask "
                         + "for a shell.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(connectors, id: \.self) { connector in
                        LabeledContent(connector) {
                            Button("Revoke all") { revoke(connector: connector) }
                                .controlSize(.small)
                        }
                        ForEach(allowedCommands.filter { $0.connector == connector }) { command in
                            AllowedCommandRow(command: command) { revoke(command) }
                        }
                    }

                    Text("Each line is the exact shape that was allowed. Anything "
                         + "different — one more argument, a different subcommand — "
                         + "has to be allowed again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Other tools") {
                Toggle("Let other tools connect over MCP", isOn: $externalAgents.isEnabled)

                Text("Opens a loopback endpoint so Claude Code, an editor or a "
                     + "script can read your tasks and propose changes. Proposals "
                     + "are reviewed here before anything is written — the same "
                     + "review the built-in assistant goes through.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if externalAgents.isEnabled {
                    LabeledContent("Port") {
                        TextField("", value: $externalAgents.port, format: .number.grouping(.never))
                            .quietField(width: 70)
                    }

                    if let endpoint = externalAgents.endpoint {
                        LabeledContent("Endpoint") {
                            Text(endpoint).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }

                    HStack {
                        Button(copiedSetup ? "Copied" : "Copy setup command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                externalAgents.setupCommand, forType: .string
                            )
                            copiedSetup = true
                        }
                        .controlSize(.small)
                        Spacer()
                        if let error = externalAgents.lastError {
                            Text(error).font(.caption).foregroundStyle(.orange)
                        } else if let activity = externalAgents.lastActivity {
                            Text("last call \(Format.time(activity))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("The token lives in ~/.config/cadence/mcp-token (mode 600) "
                         + "and survives relaunches, so a client configured once "
                         + "keeps working.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("AI CLI") {
                // Picking one rewrites the fields below rather than hiding
                // them: the flags differ per CLI and seeing which ones changed
                // is how you tell a preset from magic.
                Picker("CLI", selection: Binding(
                    get: { session.configuration.preset },
                    set: { preset in
                        guard preset != .custom else { return }
                        var updated = preset.configuration
                        updated.workingDirectory = session.configuration.workingDirectory
                        updated.timeoutSeconds = session.configuration.timeoutSeconds
                        session.configuration = updated
                        session.checkConfiguration()
                    }
                )) {
                    ForEach(CLIConfiguration.Preset.allCases) { Text($0.title).tag($0) }
                }

                TextField("Command", text: $session.configuration.command)
                    .onSubmit { session.checkConfiguration() }
                TextField("Arguments", text: Binding(
                    get: { session.configuration.arguments.joined(separator: " ") },
                    set: { session.configuration.arguments = $0.split(separator: " ").map(String.init) }
                ))
                TextField("Working directory", text: $session.configuration.workingDirectory)

                Picker("Transport", selection: $session.configuration.transport) {
                    ForEach(CLIConfiguration.Transport.allCases) { Text($0.title).tag($0) }
                }

                if session.configuration.systemPromptArguments.isEmpty {
                    Text("This CLI has no system-prompt flag, so Cadence's "
                         + "instructions are placed at the top of each prompt "
                         + "instead. Same rules, same behaviour.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if session.configuration.transport == .mcp
                    && session.configuration.mcpArguments.isEmpty {
                    Label("This CLI cannot be given a server on the command line. "
                          + "Switch Transport to JSON in / out.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Picker("Timeout", selection: $session.configuration.timeoutSeconds) {
                    ForEach([30, 60, 120, 300], id: \.self) { Text("\($0)s").tag($0) }
                }
            }

            Section("Connection") {
                HStack {
                    Button("Detect") {
                        session.checkConfiguration()
                        testResult = session.configurationProblem ?? "Found on disk."
                    }
                    Button("Test Connection") {
                        isTesting = true
                        Task {
                            testResult = await session.testConnection()
                            isTesting = false
                        }
                    }
                    .disabled(isTesting)
                    if isTesting { ProgressView().controlSize(.small) }
                }

                if let invocation = session.resolvedInvocation {
                    LabeledContent("Resolved") {
                        Text(invocation.displayPath)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }

                if let testResult {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(session.configurationProblem == nil ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                }
            }

            Section("Wrappers") {
                Text("A command that is an alias, a shell function, or on a PATH "
                     + "set in your shell's rc files is run through a login shell, "
                     + "so anything that works in Terminal works here. Whatever "
                     + "you configure must still accept the flags Cadence adds "
                     + "— --mcp-config, --output-format and --append-system-prompt "
                     + "— so a wrapper that drops unknown flags will fail.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("No API key is stored. Cadence runs your CLI, which uses its own "
                     + "sign-in. Every proposed change is reviewed by you before it is saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            session.checkConfiguration()
            reloadAllowedCommands()
        }
    }

    private func reloadAllowedCommands() {
        allowedCommands = (try? model.database.writer.read { db in
            try ApprovedCommandRepository.all(db)
        }) ?? []
    }

    private func revoke(_ command: ApprovedCommand) {
        try? model.database.writer.write { db in
            _ = try ApprovedCommandRepository.revoke(db, id: command.id)
        }
        reloadAllowedCommands()
    }

    private func revoke(connector: String) {
        try? model.database.writer.write { db in
            _ = try ApprovedCommandRepository.revoke(db, connector: connector)
        }
        reloadAllowedCommands()
    }
}

/// One allowed command, shown as the shape that was approved.
///
/// Monospaced and unwrapped-looking on purpose: this is the thing the user
/// agreed to, and a prose summary of it would be the assistant's word for what
/// it does rather than what it is.
private struct AllowedCommandRow: View {
    var command: ApprovedCommand
    var onRevoke: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.display())
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 5) {
                    Text(command.extent)
                    if !command.purpose.isEmpty {
                        Text("· \(command.purpose)")
                    }
                    if let used = command.lastUsedAt {
                        Text("· last run \(Format.date(used))")
                    } else {
                        Text("· never run")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button("Revoke", role: .destructive, action: onRevoke)
                .controlSize(.small)
                .opacity(isHovering ? 1 : 0.35)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

// MARK: - Memory

private struct UpdateSettings: View {
    @Environment(Updater.self) private var updater

    @State private var backups: [URL] = []

    var body: some View {
        @Bindable var updater = updater

        Form {
            Section("Updates") {
                LabeledContent("Version", value: updater.currentVersion.description)
                Toggle("Check automatically", isOn: $updater.checksAutomatically)
                HStack {
                    Button("Check Now") { Task { await updater.checkNow() } }
                        .disabled(updater.state.isBusy)
                    if let checked = updater.lastCheckedAt {
                        Text("last checked \(Format.dateTime(checked))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Backups") {
                Text("A snapshot of your tasks is taken before every update, and "
                     + "the update is stopped if the snapshot cannot be read back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if backups.isEmpty {
                    Text("No snapshots yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(backups.prefix(5), id: \.self) { url in
                        HStack {
                            Text(url.deletingPathExtension().lastPathComponent)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                            Spacer()
                            Text(size(of: url)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Button("Show in Finder") {
                    if let folder = try? DatabaseBackup.folder() {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .onAppear { backups = (try? DatabaseBackup.list()) ?? [] }
    }

    private func size(of url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Notifications


private struct NotificationSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(NotificationService.self) private var notifications

    var body: some View {
        @Bindable var notifications = notifications

        Form {
            Section("Reminders") {
                switch notifications.authorization {
                case .authorized:
                    Toggle("Remind me when work starts", isOn: $notifications.isEnabled)

                    Picker("Warn me before", selection: $notifications.leadTimeMinutes) {
                        Text("Not at all").tag(0)
                        ForEach([2, 5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .disabled(!notifications.isEnabled)

                case .denied:
                    Text("Notifications are turned off for Cadence. Enable them in "
                         + "System Settings › Notifications.")
                        .foregroundStyle(.secondary)

                case .unknown:
                    Button("Turn On Notifications") {
                        Task {
                            await notifications.requestAuthorization()
                            await notifications.reschedule(from: model.agendaItems)
                        }
                    }
                }
            }

            Section {
                Text("A reminder carries Complete and Snooze actions, so a block "
                     + "can be dealt with without opening the app. Only scheduled "
                     + "work is announced — an all-day task has no moment to fire at.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await notifications.refreshAuthorization() }
        .onChange(of: notifications.isEnabled) { _, _ in
            Task { await notifications.reschedule(from: model.agendaItems) }
        }
        .onChange(of: notifications.leadTimeMinutes) { _, _ in
            Task { await notifications.reschedule(from: model.agendaItems) }
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section("Appearance") {
                Picker("Theme", selection: $preferences.appAppearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Window background") {
                Picker("Style", selection: $preferences.backgroundStyle) {
                    ForEach(BackgroundStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                if preferences.backgroundStyle != .solid {
                    VStack(alignment: .leading, spacing: Metrics.tight) {
                        Slider(value: $preferences.backgroundOpacity, in: 0...1) {
                            Text("Opacity")
                        } minimumValueLabel: {
                            Image(systemName: "circle.dotted")
                        } maximumValueLabel: {
                            Image(systemName: "circle.fill")
                        }

                        Text("Left is clear glass, right is nearly solid. "
                             + "The blur samples whatever is behind the window, "
                             + "so how it reads depends on your wallpaper.")
                            .font(Typography.rowMeta)
                            .foregroundStyle(.secondaryText)
                    }
                }
            }

            Section {
                Text("Translucency is decorative and costs a little performance. "
                     + "Solid is the most legible over a busy desktop.")
                    .font(Typography.rowMeta)
                    .foregroundStyle(.secondaryText)
            }
        }
        .formStyle(.grouped)
    }
}
