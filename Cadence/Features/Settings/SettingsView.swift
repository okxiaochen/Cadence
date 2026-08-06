import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            PlanningSettings()
                .tabItem { Label("Planning", systemImage: "clock") }
            CalendarSettings()
                .tabItem { Label("Calendars", systemImage: "calendar") }
            AISettings()
                .tabItem { Label("AI", systemImage: "sparkles") }
            MemorySettings()
                .tabItem { Label("Memory", systemImage: "brain") }
        }
        .frame(width: 540, height: 420)
    }
}

private struct PlanningSettings: View {
    @Environment(Preferences.self) private var preferences

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

            Section("Scheduling") {
                Picker("Snap to", selection: $preferences.snapMinutes) {
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                }
                Picker("Default estimate", selection: $preferences.defaultEstimateMinutes) {
                    ForEach([15, 25, 30, 45, 60, 90], id: \.self) { Text(Format.duration($0)).tag($0) }
                }
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

    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        @Bindable var session = session

        Form {
            Section("AI CLI") {
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

                if let testResult {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(session.configurationProblem == nil ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                }
            }

            Section("Privacy") {
                Text("No API key is stored. Cadence runs your CLI, which uses its own "
                     + "sign-in. Every proposed change is reviewed by you before it is saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { session.checkConfiguration() }
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
