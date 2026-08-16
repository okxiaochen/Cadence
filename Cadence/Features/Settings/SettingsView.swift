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
            MemorySettings()
                .tabItem { Label("Memory", systemImage: "brain") }
            SkillSettings()
                .tabItem { Label("Skills", systemImage: "list.bullet.rectangle") }
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
                    Picker("Suggest a break after", selection: $preferences.breakAfterMinutes) {
                        ForEach([25, 40, 50, 60, 90], id: \.self) { Text("\($0)m").tag($0) }
                    }
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

                if scheduledRuns.nightlyPlanEnabled || scheduledRuns.weeklyReflectionEnabled {
                    Picker("Run at", selection: $scheduledRuns.nightlyHour) {
                        ForEach([18, 19, 20, 21, 22, 23], id: \.self) { hour in
                            Text("\(hour):00").tag(hour)
                        }
                    }
                }

                Text("Both stage a proposal for you to review in the morning and "
                     + "never write on their own. The Sunday run only updates what "
                     + "the assistant knows about how you work.")
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
                    if !command.purpose.isEmpty {
                        Text(command.purpose)
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

private struct MemorySettings: View {
    @Environment(AppModel.self) private var model

    @State private var memories: [Memory] = []
    @State private var editing: Memory?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("What the assistant remembers")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(memories.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()

            if memories.isEmpty {
                VStack(spacing: 6) {
                    Text("Nothing remembered yet.")
                        .foregroundStyle(.secondary)
                    Text("The assistant saves preferences, projects and constraints "
                         + "as it learns them.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(memories) { memory in
                        MemoryRow(memory: memory) { updated in
                            save(updated)
                        } onDelete: {
                            delete(memory)
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("Memory is written directly, without review. Everything is "
                     + "editable here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Forget All", role: .destructive) { deleteAll() }
                    .controlSize(.small)
                    .disabled(memories.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        memories = (try? model.database.writer.read { db in try MemoryRepository.all(db) }) ?? []
    }

    private func save(_ memory: Memory) {
        try? model.database.writer.write { db in try MemoryRepository.upsert(db, memory) }
        reload()
    }

    private func delete(_ memory: Memory) {
        try? model.database.writer.write { db in _ = try MemoryRepository.delete(db, id: memory.id) }
        reload()
    }

    private func deleteAll() {
        try? model.database.writer.write { db in try db.execute(sql: "DELETE FROM memory") }
        reload()
    }
}

/// What the assistant has worked out about how things are done here.
///
/// Separate from Memory because the two are different in a way that matters
/// when you are looking at them: a memory is a fact about you, a skill is a
/// procedure, and the reason to open a skill is to check whether the steps are
/// still right.
private struct SkillSettings: View {
    @Environment(AppModel.self) private var model

    @State private var skills: [Skill] = []
    @State private var forked: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("How things are done here")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(skills.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()

            if skills.isEmpty {
                VStack(spacing: 6) {
                    Text("No procedures yet.")
                        .foregroundStyle(.secondary)
                    Text("When the assistant works out how to read one of your "
                         + "tools, it writes down what worked so the next run "
                         + "does not start over.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(skills) { skill in
                        SkillRow(
                            skill: skill,
                            isForked: forked.contains(skill.id)
                        ) {
                            delete(skill)
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            Text("Built-in procedures ship with Cadence and update with it. "
                 + "Editing one keeps your version until you delete it, which "
                 + "puts the shipped one back.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        skills = (try? model.database.writer.read { db in
            try SkillRepository.all(db)
        }) ?? []
        forked = Set((try? model.database.writer.read { db in
            try SkillRepository.forkedFromBuiltIn(db)
        })?.map(\.id) ?? [])
    }

    private func delete(_ skill: Skill) {
        try? model.database.writer.write { db in
            _ = try SkillRepository.delete(db, id: skill.id)
        }
        reload()
    }
}

private struct SkillRow: View {
    var skill: Skill
    var isForked: Bool
    var onDelete: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(skill.title).font(.callout.weight(.medium))
                    // The line that is always loaded, so it is the line worth
                    // reading: it is what makes the assistant reach for this.
                    Text(skill.whenToUse)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 2)
                }

                Spacer(minLength: 0)

                if skill.isStale() {
                    Text("unverified")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.18), in: Capsule())
                }
                Text(skill.isBuiltIn ? "Built in" : skill.source)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())

                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)

                // A built-in has no stored row to remove; only an override or
                // something the assistant wrote can be deleted.
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(skill.isBuiltIn)
                .opacity(skill.isBuiltIn ? 0.25 : 1)
            }

            if isForked {
                Label("The version that ships with Cadence has been updated "
                      + "since you changed this one. Deleting yours restores it.",
                      systemImage: "arrow.triangle.branch")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if isExpanded {
                Text(skill.body.isEmpty ? "No steps recorded." : skill.body)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 2)
    }
}

private struct MemoryRow: View {
    @State var memory: Memory
    var onSave: (Memory) -> Void
    var onDelete: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Toggle(isOn: Binding(
                    get: { memory.pinned },
                    set: { memory.pinned = $0; onSave(memory) }
                )) {
                    Image(systemName: memory.pinned ? "pin.fill" : "pin")
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .help("Pinned memories are loaded in full every time")

                VStack(alignment: .leading, spacing: 1) {
                    Text(memory.title).font(.callout.weight(.medium))
                    Text(memory.summary).font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                Text(memory.categoryValue.title)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())

                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Summary", text: $memory.summary, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { onSave(memory) }
                    TextEditor(text: $memory.body)
                        .font(.caption)
                        .frame(minHeight: 60)
                        .border(.quaternary)
                    HStack {
                        Text("key: \(memory.id)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("updated \(Format.date(memory.updatedAt))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Button("Save") { onSave(memory) }
                            .controlSize(.small)
                    }
                }
                .padding(.leading, 26)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Updates

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
