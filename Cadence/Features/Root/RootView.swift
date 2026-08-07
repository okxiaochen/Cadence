import SwiftUI

enum WorkspaceMode: String, CaseIterable, Identifiable, Hashable {
    case list, calendar, split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: "List"
        case .calendar: "Calendar"
        case .split: "Split"
        }
    }

    var symbolName: String {
        switch self {
        case .list: "list.bullet"
        case .calendar: "calendar.day.timeline.left"
        case .split: "rectangle.split.2x1"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AgentSession.self) private var session
    @Environment(Preferences.self) private var preferences
    @Environment(NotificationService.self) private var notifications
    @Environment(\.undoManager) private var undoManager

    @State private var detailPanel: TaskDetailPanelController?

    @State private var showsAssistant = false
    @AppStorage("workspaceMode") private var mode: WorkspaceMode = .list

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            SidebarView()
                .matchesWindowMaterial(preferences.background)
        } detail: {
            HStack(spacing: 0) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsAssistant {
                    Divider()
                    AIPanelView()
                }
            }
            .toolbar { toolbar }
            .safeAreaInset(edge: .top, spacing: 0) { UpdateBanner() }
        }
        .frame(minWidth: 900, minHeight: 560)
        // Always hidden. The toolbar's own material is a different shade from
        // the window in every mode, and it is the one band that spans the full
        // width, so the mismatch is the first thing the eye finds.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .windowBackground(preferences.background)
        .onAppear {
            model.undoManager = undoManager
            model.publishToCalendar()
        }
        // Reminders are rebuilt from the agenda whenever it changes, so a
        // rescheduled block can never leave a stale alert behind.
        .task(id: model.agendaItems) {
            await notifications.reschedule(from: model.agendaItems)
        }
        .task(id: model.inspectedID) {
            if detailPanel == nil {
                detailPanel = TaskDetailPanelController(
                    model: model, session: session, preferences: preferences
                )
            }
            detailPanel?.sync()
        }
        .onChange(of: undoManager) { _, newValue in model.undoManager = newValue }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            presenting: model.errorMessage
        ) { _ in
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch mode {
        case .list:
            TodoListView()
        case .calendar:
            CalendarView()
        case .split:
            // Planning mode: drag from the list on the left onto the grid.
            PaneSplit(storageKey: "splitLeadingWidth") {
                TodoListView()
            } trailing: {
                CalendarView()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Mode", selection: $mode) {
                ForEach(WorkspaceMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbolName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        ToolbarItem {
            Button {
                showsAssistant.toggle()
            } label: {
                Label("Assistant", systemImage: "sparkles")
            }
            .keyboardShortcut("/", modifiers: .command)
        }
    }
}
