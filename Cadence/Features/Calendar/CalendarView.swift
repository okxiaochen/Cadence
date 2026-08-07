import AppKit
import SwiftUI

struct CalendarView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences
    @Environment(AgentSession.self) private var session

    @State private var drag: ActiveDrag?
    @State private var didScrollToStart = false
    @State private var isDropTargeted = false

    private let gutterWidth: CGFloat = 54
    private let headerHeight: CGFloat = 44

    private var days: [Date] { model.visibleDays }
    private var snap: Int { preferences.snapMinutes }

    var body: some View {
        VStack(spacing: 0) {
            CalendarHeaderBar()
            Divider()
            if model.eventKit.access != .authorized {
                calendarAccessBanner
            }
            dayHeaderRow
            Divider()
            grid
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.refreshBusyEvents() }
        .onDeleteCommand { deleteSelectedBlock() }
        .focusable()
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
            Text(model.eventKit.access == .denied
                 ? "Calendar access denied — enable it in System Settings › Privacy to see busy time."
                 : "Show your existing events as busy time?")
                .font(.callout)
            Spacer()
            if model.eventKit.access != .denied {
                Button("Connect Calendar") {
                    Task {
                        await model.eventKit.requestAccess()
                        model.refreshBusyEvents()
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.12))
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

                ForEach(model.positionedBlocks) { positioned in
                    blockView(positioned, geometry: geometry)
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
        .offset(x: rect.minX, y: rect.minY)
        .onTapGesture { model.selectedBlockID = positioned.id }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { model.inspectedID = positioned.block.todo.id }
        )
        .gesture(moveGesture(positioned, geometry: geometry))
        .overlay(alignment: .top) {
            // A short block has no room for a top handle without swallowing the
            // whole thing; resize it from the bottom instead.
            if rect.height >= 28 {
                resizeHandle(positioned, geometry: geometry, edge: .start, blockHeight: rect.height)
            }
        }
        .overlay(alignment: .bottom) {
            resizeHandle(positioned, geometry: geometry, edge: .end, blockHeight: rect.height)
        }
        .contextMenu {
            Button("Show Details…") { model.inspectedID = positioned.block.todo.id }
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

    private func moveGesture(_ positioned: PositionedBlock, geometry: CalendarGeometry) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.gridSpace))
            .onChanged { value in
                let original = positioned.block.interval
                let current = drag?.blockID == positioned.id
                    ? drag!
                    : ActiveDrag(
                        blockID: positioned.id,
                        mode: .move,
                        interval: original,
                        isDuplicate: false,
                        // Keep the point you grabbed under the cursor.
                        grabOffset: value.startLocation.y - geometry.y(for: original.start)
                    )

                let target = geometry.date(
                    at: CGPoint(x: value.location.x, y: value.location.y - current.grabOffset),
                    snapMinutes: snap
                )
                var next = current
                next.interval = geometry.reposition(original, toStart: target)
                drag = next
                model.selectedBlockID = positioned.id
            }
            .onEnded { _ in
                defer { drag = nil }
                guard let finished = drag, finished.blockID == positioned.id,
                      finished.interval != positioned.block.interval else { return }
                model.setBlockInterval(positioned.id, to: finished.interval)
            }
    }

    private enum Edge { case start, end }

    @ViewBuilder
    private func resizeHandle(
        _ positioned: PositionedBlock,
        geometry: CalendarGeometry,
        edge: Edge,
        blockHeight: CGFloat
    ) -> some View {
        ResizeHandle(height: min(10, max(5, blockHeight / 3)))
            // High priority, or the block's own move gesture wins the
            // arbitration and the edge drags the whole block instead.
            .highPriorityGesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.gridSpace))
                    .onChanged { value in
                        let original = positioned.block.interval
                        // Locked to the block's own day: dragging an edge
                        // sideways must not send it to another column.
                        let edgeDate = geometry.date(
                            onDay: original.start,
                            atY: value.location.y,
                            snapMinutes: snap
                        )
                        let minimum = TimeInterval(max(5, snap) * 60)

                        var interval = original
                        switch edge {
                        case .start:
                            interval.start = min(edgeDate, original.end.addingTimeInterval(-minimum))
                            interval.end = original.end
                        case .end:
                            interval.end = max(edgeDate, original.start.addingTimeInterval(minimum))
                        }
                        drag = ActiveDrag(
                            blockID: positioned.id,
                            mode: edge == .start ? .resizeStart : .resizeEnd,
                            interval: interval,
                            isDuplicate: false,
                            grabOffset: 0
                        )
                    }
                    .onEnded { _ in
                        defer { drag = nil }
                        guard let finished = drag, finished.blockID == positioned.id,
                              finished.interval != positioned.block.interval else { return }
                        model.setBlockInterval(positioned.id, to: finished.interval, actionName: "Resize Block")
                    }
            )
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

            Picker("", selection: $model.calendarScale) {
                ForEach(CalendarScale.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
                      ? Color.accentColor.opacity(0.04)
                      : Color.clear)

            // Working hours read as the "live" part of the day.
            if let hours = preferences.workingHours(on: day) {
                Rectangle()
                    .fill(Color.primary.opacity(0.035))
                    .frame(height: geometry.height(for: hours))
                    .offset(y: geometry.y(for: hours.start))
            }

            ForEach(model.busyEvents(on: day)) { event in
                busyEvent(event)
            }

            Rectangle()
                .fill(Color.primary.opacity(0.08))
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
                    .fill(Color.primary.opacity(hour % 6 == 0 ? 0.12 : 0.06))
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

/// The drag target at a block's top and bottom edge.
///
/// `NSCursor.push()/pop()` in an `onHover` is a trap: hover enter and exit do
/// not always pair, and an unbalanced pop corrupts the cursor stack for the
/// whole app. This tracks its own push instead.
private struct ResizeHandle: View {
    var height: CGFloat

    @State private var isHovering = false
    @State private var hasPushedCursor = false

    var body: some View {
        Color.clear
            .frame(height: height)
            .contentShape(Rectangle())
            .overlay {
                if isHovering {
                    Capsule()
                        .fill(.primary.opacity(0.55))
                        .frame(width: 18, height: 3)
                }
            }
            .onHover { inside in
                isHovering = inside
                if inside, !hasPushedCursor {
                    NSCursor.resizeUpDown.push()
                    hasPushedCursor = true
                } else if !inside, hasPushedCursor {
                    NSCursor.pop()
                    hasPushedCursor = false
                }
            }
            .onDisappear {
                if hasPushedCursor {
                    NSCursor.pop()
                    hasPushedCursor = false
                }
            }
    }
}
