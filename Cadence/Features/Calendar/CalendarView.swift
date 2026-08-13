import AppKit
import SwiftUI

struct CalendarView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences
    @Environment(AgentSession.self) private var session

    @State private var drag: ActiveDrag?
    @State private var hover: HoverState?
    @State private var didScrollToStart = false
    @State private var isDropTargeted = false

    private let gutterWidth: CGFloat = 54
    private let headerHeight: CGFloat = 44

    private var days: [Date] { model.visibleDays }
    private var snap: Int { preferences.snapMinutes }

    var body: some View {
        VStack(spacing: 0) {
            CalendarHeaderBar()
            if model.eventKit.access != .authorized {
                calendarAccessBanner
            }
            dayHeaderRow
            Rectangle().fill(.hairline).frame(height: 1)
            grid
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.refreshBusyEvents() }
        .onDeleteCommand { deleteSelectedBlock() }
        // Focusable so ⌫ reaches onDeleteCommand, but a focus ring drawn around
        // the whole calendar is just noise.
        .focusable()
        .focusEffectDisabled()
    }

    // MARK: - Header

    private var dayHeaderRow: some View {
        HStack(spacing: 0) {
            // A bare `Color.clear.frame(width:)` is flexible vertically and
            // stretches this row to fill the window; pin the height too.
            Color.clear.frame(width: gutterWidth, height: dayHeaderHeight)
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                DayHeader(
                    day: day,
                    allDayEvents: model.allDayEvents(on: day),
                    dueTasks: model.dueTasks(on: day)
                )
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: dayHeaderHeight)
    }

    /// Grows only as far as the all-day lane needs.
    private var dayHeaderHeight: CGFloat {
        let rows = days
            .map { model.allDayEvents(on: $0).count + model.dueTasks(on: $0).count }
            .max() ?? 0
        return headerHeight + CGFloat(min(3, rows)) * 17
    }

    private var calendarAccessBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .foregroundStyle(.secondaryText)
            Text(model.eventKit.access == .denied
                 ? "Calendar access denied — enable it in System Settings › Privacy to see busy time."
                 : "Show your existing events as busy time?")
                .font(Typography.rowMeta)
                .foregroundStyle(.secondaryText)
            Spacer()
            if model.eventKit.access != .denied {
                // A link, not a bordered button: this is a one-off invitation
                // sitting on a translucent banner, and a filled capsule there
                // reads as the loudest control in the window.
                Button("Connect Calendar") {
                    Task {
                        await model.eventKit.requestAccess()
                        model.refreshBusyEvents()
                    }
                }
                .buttonStyle(.link)
                .font(Typography.rowMeta.weight(.medium))
            }
        }
        .padding(.horizontal, Metrics.comfortable)
        .padding(.vertical, Metrics.snug)
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollViewReader { scroller in
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    TimeGutter(hourHeight: preferences.hourHeight)
                        .frame(width: gutterWidth)
                    gridBody
                }
                .frame(height: CalendarGeometry.hoursPerDay * preferences.hourHeight)
                .background(scrollAnchors)
            }
            .onAppear {
                guard !didScrollToStart else { return }
                didScrollToStart = true
                // Open on the working day, not on midnight.
                scroller.scrollTo("hour-\(max(0, preferences.workdayStartHour - 1))", anchor: .top)
            }
        }
    }

    /// Invisible per-hour anchors so `scrollTo` can land on a time.
    private var scrollAnchors: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Color.clear
                    .frame(height: preferences.hourHeight)
                    .id("hour-\(hour)")
            }
        }
    }

    private var gridBody: some View {
        GeometryReader { proxy in
            let geometry = CalendarGeometry(
                days: days,
                dayWidth: proxy.size.width / CGFloat(max(1, days.count)),
                hourHeight: preferences.hourHeight
            )

            ZStack(alignment: .topLeading) {
                DayBackgrounds(geometry: geometry, model: model, preferences: preferences)

                // The plan and the record, in one layout: what actually
                // happened sits beside what was planned for that hour.
                ForEach(model.positionedEntries) { positioned in
                    switch positioned.entry.kind {
                    case .planned(let block):
                        blockView(
                            PositionedBlock(
                                block: block,
                                dayIndex: positioned.dayIndex,
                                column: positioned.column,
                                columnCount: positioned.columnCount,
                                span: positioned.span
                            ),
                            geometry: geometry
                        )
                    case .tracked(let session):
                        sessionView(session, positioned: positioned, geometry: geometry)
                    }
                }

                if let drag, drag.isDuplicate {
                    ghost(drag.interval, geometry: geometry)
                }

                // AI proposals appear in situ, so a plan is read on the grid
                // rather than as a list of times (AI-INTEGRATION.md §5).
                if let proposal = session.proposal {
                    ForEach(proposal.ghostIntervals, id: \.id) { item in
                        ghost(item.interval, geometry: geometry, title: item.taskTitle)
                    }
                }

                CurrentTimeIndicator(geometry: geometry)
            }
            .coordinateSpace(.named(Self.gridSpace))
            // Without an explicit content shape the ZStack has no hittable
            // area between blocks, so drops onto empty grid never register.
            .contentShape(Rectangle())
            .onDrop(
                of: [TaskDrag.typeIdentifier],
                delegate: CalendarDropDelegate(
                    onEnterExit: { isDropTargeted = $0 },
                    onDrop: { location, ids in
                        drop(ids, at: location, geometry: geometry)
                    }
                )
            )
            .overlay {
                if isDropTargeted {
                    Rectangle()
                        .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ positioned: PositionedBlock, geometry: CalendarGeometry) -> some View {
        let isDragging = drag?.blockID == positioned.id && !(drag?.isDuplicate ?? false)
        let interval = isDragging ? drag!.interval : positioned.block.interval
        let dayIndex = isDragging
            ? (geometry.dayIndex(of: interval.start) ?? positioned.dayIndex)
            : positioned.dayIndex
        let rect = geometry.rect(
            interval: interval,
            dayIndex: dayIndex,
            // A block being dragged floats above the packing of its neighbours.
            column: isDragging ? 0 : positioned.column,
            columnCount: isDragging ? 1 : positioned.columnCount,
            span: isDragging ? 1 : positioned.span
        )

        BlockView(
            block: positioned.block,
            interval: interval,
            height: rect.height,
            isSelected: model.selectedBlockID == positioned.id,
            isDragging: isDragging,
            conflicts: conflicts(interval, excluding: positioned.id)
        )
        .frame(width: rect.width, height: rect.height, alignment: .top)
        // Before `.offset`, not after: `.offset` moves rendering and hit
        // testing but leaves the *layout* frame where it was, so an overlay
        // added afterwards is positioned against the un-offset frame and draws
        // adrift near the grid's origin.
        .overlay {
            ResizeAffordance(height: rect.height, hovering: hoverMode(for: positioned.id))
        }
        .offset(x: rect.minX, y: rect.minY)
        .onTapGesture { model.selectedBlockID = positioned.id }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { model.inspectedID = positioned.block.todo.id }
        )
        .gesture(blockGesture(positioned, geometry: geometry, rect: rect))
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                hover = HoverState(
                    blockID: positioned.id,
                    mode: Self.mode(for: point.y, height: rect.height)
                )
            case .ended:
                if hover?.blockID == positioned.id { hover = nil }
            }
        }
        .contextMenu {
            Button("Show Details…") { model.inspectedID = positioned.block.todo.id }
            Button(model.isTiming(positioned.block.todo.id) ? "Stop Timer" : "Start Timer") {
                model.toggleTimer(for: positioned.block.todo.id)
            }
            Divider()
            Menu("Duration") {
                ForEach([15, 30, 45, 60, 90, 120], id: \.self) { minutes in
                    Button(Format.duration(minutes)) {
                        model.setBlockDuration(positioned.id, minutes: minutes)
                    }
                }
            }
            Divider()
            Button("Unschedule") { model.deleteBlock(positioned.id) }
        }
        .zIndex(isDragging ? 10 : 0)
    }

    /// Recorded time. Not draggable: a record of what happened is corrected in
    /// the inspector, where the exact times are, rather than by nudging it
    /// around a grid.
    @ViewBuilder
    private func sessionView(
        _ session: TrackedSession,
        positioned: PositionedEntry,
        geometry: CalendarGeometry
    ) -> some View {
        let rect = geometry.rect(
            interval: positioned.entry.interval,
            dayIndex: positioned.dayIndex,
            column: positioned.column,
            columnCount: positioned.columnCount,
            span: positioned.span
        )

        SessionBlockView(
            session: session,
            interval: positioned.entry.interval,
            // A ten-minute session is four points tall at the default zoom —
            // true to the clock and useless to read. Recorded time gets a floor
            // so its title always has somewhere to go.
            height: max(SessionBlockView.minimumHeight, rect.height)
        )
        .frame(width: rect.width, alignment: .top)
        .offset(x: rect.minX, y: rect.minY)
        .onTapGesture { model.inspectedID = session.todo.id }
        .contextMenu {
            Button("Show Details…") { model.inspectedID = session.todo.id }
            if session.entry.isRunning {
                Button("Stop Timer") { model.stopTimer(for: session.todo.id) }
            }
            Divider()
            Button("Delete Entry", role: .destructive) {
                model.deleteProgress(session.entry)
            }
        }
    }

    @ViewBuilder
    private func ghost(
        _ interval: DateInterval,
        geometry: CalendarGeometry,
        title: String? = nil
    ) -> some View {
        if let dayIndex = geometry.dayIndex(of: interval.start) {
            let rect = geometry.rect(interval: interval, dayIndex: dayIndex, column: 0, columnCount: 1)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.tint.opacity(0.08))
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .foregroundStyle(.tint)
                if let title {
                    Text(title)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .padding(.top, 3)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Gestures

    /// Move and resize in a single gesture, chosen by where the press landed.
    ///
    /// Two overlapping gestures — one on the block, one on an edge handle —
    /// never arbitrated reliably: the block's own drag kept winning, so the
    /// edge moved the whole block instead of resizing it. Deciding from the
    /// start position removes the contest altogether.
    private func blockGesture(
        _ positioned: PositionedBlock,
        geometry: CalendarGeometry,
        rect: CGRect
    ) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.gridSpace))
            .onChanged { value in
                let original = positioned.block.interval
                let existing = drag?.blockID == positioned.id ? drag : nil
                let mode = existing?.mode
                    ?? Self.mode(for: value.startLocation.y - rect.minY, height: rect.height)
                let minimum = TimeInterval(max(5, snap) * 60)

                switch mode {
                case .move:
                    let grabOffset = existing?.grabOffset
                        ?? (value.startLocation.y - geometry.y(for: original.start))
                    let target = geometry.date(
                        at: CGPoint(x: value.location.x, y: value.location.y - grabOffset),
                        snapMinutes: snap
                    )
                    drag = ActiveDrag(
                        blockID: positioned.id,
                        mode: .move,
                        interval: geometry.reposition(original, toStart: target),
                        isDuplicate: false,
                        grabOffset: grabOffset
                    )

                case .resizeStart, .resizeEnd:
                    // Locked to the block's own day: dragging an edge sideways
                    // must not send it to another column.
                    let edge = geometry.date(
                        onDay: original.start,
                        atY: value.location.y,
                        snapMinutes: snap
                    )
                    var interval = original
                    if mode == .resizeStart {
                        interval.start = min(edge, original.end.addingTimeInterval(-minimum))
                        interval.end = original.end
                    } else {
                        interval.end = max(edge, original.start.addingTimeInterval(minimum))
                    }
                    drag = ActiveDrag(
                        blockID: positioned.id,
                        mode: mode,
                        interval: interval,
                        isDuplicate: false,
                        grabOffset: 0
                    )
                }
            }
            .onEnded { _ in
                defer { drag = nil }
                guard let finished = drag, finished.blockID == positioned.id,
                      finished.interval != positioned.block.interval else { return }
                model.setBlockInterval(
                    positioned.id,
                    to: finished.interval,
                    actionName: finished.mode == .move ? "Move Block" : "Resize Block"
                )
            }
    }

    struct HoverState: Equatable {
        var blockID: String
        var mode: ActiveDrag.Mode
    }

    private func hoverMode(for blockID: String) -> ActiveDrag.Mode? {
        hover?.blockID == blockID ? hover?.mode : nil
    }

    /// How much of each end of a block starts a resize rather than a move.
    ///
    /// Capped so a tall block does not devote a third of itself to resizing,
    /// and zero below a threshold: on a very short block two edge zones would
    /// meet in the middle and leave nothing to drag the block *by*. Those are
    /// resized from the Duration menu instead.
    static let minimumResizableHeight: CGFloat = 16

    static func resizeZone(forHeight height: CGFloat) -> CGFloat {
        guard height >= minimumResizableHeight else { return 0 }
        return min(12, max(4, height / 3))
    }

    static func mode(for offsetY: CGFloat, height: CGFloat) -> ActiveDrag.Mode {
        let zone = resizeZone(forHeight: height)
        guard zone > 0 else { return .move }
        if offsetY <= zone { return .resizeStart }
        if offsetY >= height - zone { return .resizeEnd }
        return .move
    }

    private func drop(_ ids: [String], at location: CGPoint, geometry: CalendarGeometry) {
        let start = geometry.date(at: location, snapMinutes: snap)
        for id in ids {
            model.schedule(todoID: id, at: start)
        }
    }

    private func deleteSelectedBlock() {
        guard let id = model.selectedBlockID else { return }
        model.deleteBlock(id)
    }

    private func conflicts(_ interval: DateInterval, excluding blockID: String) -> Bool {
        model.conflictIntervals(excluding: blockID).contains { $0.overlaps(interval) }
    }

    static let gridSpace = "cadence.calendar.grid"
}

// MARK: - Drag state

struct ActiveDrag: Equatable {
    enum Mode { case move, resizeStart, resizeEnd }

    var blockID: String
    var mode: Mode
    var interval: DateInterval
    var isDuplicate: Bool
    /// Distance from the block's top edge to where the cursor grabbed it.
    var grabOffset: CGFloat
}

// MARK: - Header bar

private struct CalendarHeaderBar: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences

    var body: some View {
        // Everything is `fixedSize`, and `ViewThatFits` sheds the title and then
        // the zoom controls as the pane narrows. Without this SwiftUI compresses
        // the controls until their labels wrap one character per line.
        ViewThatFits(in: .horizontal) {
            bar(showsTitle: true, showsZoom: true)
            bar(showsTitle: true, showsZoom: false)
            bar(showsTitle: false, showsZoom: false)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, Metrics.comfortable)
        .padding(.vertical, Metrics.regular)
    }

    private func bar(showsTitle: Bool, showsZoom: Bool) -> some View {
        @Bindable var model = model

        return HStack(spacing: 10) {
            Button { model.stepCalendar(by: -1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: .option)
                .help("Previous")

            Button("Today") { model.goToToday() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .lineLimit(1)
                .fixedSize()
                .help("Jump back to today (⇧⌘T)")

            Button { model.stepCalendar(by: 1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: .option)
                .help("Next")

            if showsTitle {
                Text(rangeTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .fixedSize()
            }

            Spacer(minLength: 8)

            QuietSegmentedPicker(
                options: CalendarScale.allCases.map { ($0, $0.title) },
                selection: $model.calendarScale
            )
            .fixedSize()

            if showsZoom {
                Button { preferences.hourHeight -= 8 } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out")
                Button { preferences.hourHeight += 8 } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in")
            }
        }
    }

    private var rangeTitle: String {
        let days = model.visibleDays
        guard let first = days.first, let last = days.last else { return "" }
        if days.count == 1 {
            return first.formatted(.dateTime.weekday(.wide).month(.wide).day())
        }
        let sameMonth = Calendar.current.isDate(first, equalTo: last, toGranularity: .month)
        return sameMonth
            ? "\(first.formatted(.dateTime.month(.wide).day()))–\(last.formatted(.dateTime.day())), \(first.formatted(.dateTime.year()))"
            : "\(first.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day()))"
    }
}

// MARK: - Day header

private struct DayHeader: View {
    @Environment(AppModel.self) private var model

    var day: Date
    var allDayEvents: [BusyEvent]
    var dueTasks: [TodoDetail]

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        VStack(spacing: 2) {
            Text(day.formatted(.dateTime.weekday(.abbreviated)))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(day.formatted(.dateTime.day()))
                .font(.title3.weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.accentColor : .primary)

            ForEach(allDayEvents.prefix(2)) { event in
                Text(event.title)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: event.colorHex).opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
            }

            // A due date has no time of day, so it belongs in the all-day lane
            // rather than anywhere in the grid.
            ForEach(dueTasks.prefix(3)) { detail in
                HStack(spacing: 3) {
                    Image(systemName: "flag.fill").font(.system(size: 7))
                    Text(detail.todo.title).lineLimit(1)
                }
                .font(.caption2)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(hex: detail.project?.colorHex ?? Palette.unassignedBlockColor).opacity(0.22),
                    in: RoundedRectangle(cornerRadius: 3)
                )
                .contentShape(Rectangle())
                .onTapGesture { model.inspectedID = detail.id }
                .help("Due today — \(detail.todo.title)")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
    }
}

// MARK: - Grid background

private struct DayBackgrounds: View {
    var geometry: CalendarGeometry
    var model: AppModel
    var preferences: Preferences

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(geometry.days.enumerated()), id: \.offset) { index, day in
                dayColumn(day, index: index)
            }
            hourLines
        }
    }

    private func dayColumn(_ day: Date, index: Int) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Calendar.current.isDateInToday(day)
                      ? Color.accentColor.opacity(0.05)
                      : Color.clear)


            ForEach(model.busyEvents(on: day)) { event in
                busyEvent(event)
            }

            Rectangle()
                .fill(Color.primary.opacity(0.045))
                .frame(width: 1)
                .frame(maxHeight: .infinity, alignment: .leading)
        }
        .frame(width: geometry.dayWidth, height: geometry.totalHeight)
        .offset(x: geometry.x(forDayIndex: index))
    }

    private func busyEvent(_ event: BusyEvent) -> some View {
        let interval = DateInterval(start: event.start, end: max(event.end, event.start.addingTimeInterval(300)))
        return HStack(spacing: 3) {
            Rectangle()
                .fill(Color(hex: event.colorHex).opacity(0.7))
                .frame(width: 2)
            Text(event.title)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(width: geometry.dayWidth - 4, height: geometry.height(for: interval), alignment: .topLeading)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 3))
        .offset(x: 2, y: geometry.y(for: interval.start))
        .allowsHitTesting(false)
    }

    private var hourLines: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Rectangle()
                    .fill(Color.primary.opacity(hour % 6 == 0 ? 0.07 : 0.035))
                    .frame(height: 1)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .frame(height: geometry.hourHeight, alignment: .top)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct TimeGutter: View {
    var hourHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(label(hour))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 6)
                    .frame(height: hourHeight, alignment: .top)
                    .offset(y: -5)
            }
        }
    }

    private func label(_ hour: Int) -> String {
        guard hour > 0 else { return "" }
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }
}

private struct CurrentTimeIndicator: View {
    @Environment(AppModel.self) private var model

    var geometry: CalendarGeometry

    private var now: Date { model.clock }

    var body: some View {
        Group {
            if let index = geometry.dayIndex(of: now) {
                ZStack(alignment: .leading) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                    Rectangle()
                        .fill(Color.red)
                        .frame(height: 1)
                        .padding(.leading, 3)
                }
                .frame(width: geometry.dayWidth)
                .offset(x: geometry.x(forDayIndex: index), y: geometry.y(for: now) - 3)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Shows where the resize zones are, and sets the cursor over them.
///
/// Deliberately not hit-testable: an overlay that can be hit is what stopped
/// the resize working twice before. The block reports hover position and the
/// zone is computed with the same maths the gesture uses, so what is shown and
/// what happens cannot disagree.
private struct ResizeAffordance: View {
    var height: CGFloat
    var hovering: ActiveDrag.Mode?

    var body: some View {
        VStack(spacing: 0) {
            grip(visible: hovering == .resizeStart)
            Spacer(minLength: 0)
            if height >= 24 { grip(visible: hovering == .resizeEnd) }
        }
        .allowsHitTesting(false)
        .onChange(of: hovering) { _, mode in
            CursorStack.shared.setResize(mode == .resizeStart || mode == .resizeEnd)
        }
        .onDisappear { CursorStack.shared.setResize(false) }
    }

    private func grip(visible: Bool) -> some View {
        Capsule()
            .fill(.primary.opacity(visible ? 0.55 : 0))
            .frame(width: 18, height: 3)
            .frame(maxWidth: .infinity, minHeight: CalendarView.resizeZone(forHeight: height))
    }
}

/// One place that owns the resize cursor.
///
/// `NSCursor.push()/pop()` from a view is a trap: hover enter and exit do not
/// always pair, and an unbalanced pop corrupts the cursor stack for the whole
/// app. A single owner tracking one boolean cannot get out of step.
@MainActor
final class CursorStack {
    static let shared = CursorStack()

    private var pushed: NSCursor?

    func setResize(_ active: Bool) {
        set(active ? NSCursor.resizeUpDown : nil)
    }

    func setColumnResize(_ active: Bool) {
        set(active ? NSCursor.resizeLeftRight : nil)
    }

    /// One push outstanding at a time, so the stack cannot drift however hover
    /// events happen to interleave.
    private func set(_ cursor: NSCursor?) {
        guard cursor !== pushed else { return }
        if pushed != nil { NSCursor.pop() }
        cursor?.push()
        pushed = cursor
    }
}
