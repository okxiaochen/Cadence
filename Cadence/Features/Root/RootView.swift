import SwiftUI

/// The three things this app is, in the order they matter.
///
/// It began as a task manager with an assistant bolted to the side, and the
/// window said so: a list, a calendar, and a column you could open. What it is
/// now is a companion that happens to hold your calendar — so talking to it is
/// the window, and the schedule is one of the things it can do rather than the
/// thing it is.
///
/// Knowledge sits in the middle deliberately. It is the assistant's own account
/// of who you are, it is written unreviewed, and it is wrong often enough that
/// burying it is how every answer drawn from it goes quietly stale.
enum Workspace: String, CaseIterable, Identifiable, Hashable {
    case chat, knowledge, schedule

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .knowledge: "Knowledge"
        case .schedule: "Schedule"
        }
    }

    var symbolName: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .knowledge: "brain"
        case .schedule: "calendar"
        }
    }
}

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
    @State private var shelf: KnowledgeView.Shelf = .memories

    @AppStorage("workspace") private var workspace: Workspace = .chat
    @AppStorage("workspaceMode") private var mode: WorkspaceMode = .list

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            sidebar
                .matchesWindowMaterial(preferences.background)
                .background(QuietSplitDivider())
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar { toolbar }
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        UpdateBanner()
                        ExternalProposalBanner()
                    }
                }
        }
        .frame(minWidth: minimumWindowWidth, minHeight: 560)
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

    /// One column, whose contents belong to whichever workspace is open.
    ///
    /// A sidebar that emptied itself in two of the three would read as a bug,
    /// and hiding the column instead moves the whole window sideways every time
    /// you switch — which is why each workspace brings its own.
    @ViewBuilder
    private var sidebar: some View {
        switch workspace {
        case .chat: ConversationSidebar()
        case .knowledge: KnowledgeSidebar(shelf: $shelf)
        case .schedule: SidebarView()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch workspace {
        case .chat:
            AIPanelView(isPrimary: true)
        case .knowledge:
            KnowledgeView(shelf: $shelf)
        case .schedule:
            schedule
        }
    }

    @ViewBuilder
    private var schedule: some View {
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

    /// The window's minimum tracks what is actually on screen. A fixed 900 was
    /// narrower than Split mode alone needs, so the panes overlapped instead of
    /// the window growing.
    private var minimumWindowWidth: CGFloat {
        // The sidebar's own minimum column width, from `SidebarView`.
        let sidebar: CGFloat = 180
        let content: CGFloat = switch workspace {
        case .chat: AIPanelView.minimumWidth + 120
        case .knowledge: 420
        case .schedule: mode == .split ? PaneSplitMetrics.minimumWidth : 420
        }
        return sidebar + content
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Workspace", selection: $workspace) {
                ForEach(Workspace.allCases) { workspace in
                    Label(workspace.title, systemImage: workspace.symbolName)
                        .tag(workspace)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        // Only where it means anything. A list/calendar/split control sitting
        // greyed out beside a conversation is three controls' worth of noise to
        // say one thing: that they are not for this.
        if workspace == .schedule {
            ToolbarItem {
                Picker("Mode", selection: $mode) {
                    ForEach(WorkspaceMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbolName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}
