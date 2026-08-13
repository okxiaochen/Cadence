import SwiftUI

/// What a stretch of days actually contained.
///
/// The per-task timeline answers "where did this one get to"; this answers the
/// question you ask on a Friday — where did the week go, and what came of it.
/// Both totals and narrative: a number without the notes is a timesheet, and
/// the notes without the numbers are a diary.
struct TimeReportView: View {
    @Environment(AppModel.self) private var model

    @State private var range: ReportRange = .thisWeek

    private var report: TimeReport { model.timeReport(in: range.interval(now: model.clock)) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if report.lines.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.section) {
                        totals
                        byProject
                        byTask
                        diary
                    }
                    .padding(Metrics.loose)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 520)
        .windowBackground(Preferences.shared.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Metrics.regular) {
            QuietSegmentedPicker(
                options: ReportRange.allCases.map { ($0, $0.title) },
                selection: $range
            )
            Spacer(minLength: Metrics.regular)
            Text(range.subtitle(now: model.clock))
                .font(Typography.rowMeta)
                .foregroundStyle(.secondaryText)
        }
        .padding(.horizontal, Metrics.loose)
        .padding(.vertical, Metrics.comfortable)
    }

    private var empty: some View {
        VStack(spacing: Metrics.regular) {
            Image(systemName: "stopwatch")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.quaternary)
            Text("Nothing recorded in this period")
                .font(.system(size: 13, weight: .medium))
            Text("Time a task, or log time you already spent.")
                .font(Typography.rowMeta)
                .foregroundStyle(.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Totals

    private var totals: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.section) {
            figure(Format.duration(report.totalMinutes), "tracked")
            figure("\(report.sessions.count)", report.sessions.count == 1 ? "session" : "sessions")
            figure("\(report.byTask().count)", "tasks")
            if !report.notes.isEmpty {
                figure("\(report.notes.count)", report.notes.count == 1 ? "note" : "notes")
            }
            Spacer(minLength: 0)
        }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 20, weight: .medium).monospacedDigit())
            Text(label)
                .font(Typography.rowMeta)
                .foregroundStyle(.secondaryText)
        }
    }

    // MARK: - Breakdowns

    private var byProject: some View {
        let rows = report.byProject()
        let maximum = rows.first?.minutes ?? 1

        return VStack(alignment: .leading, spacing: Metrics.regular) {
            SectionHeader(title: "By project", count: nil)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: Metrics.regular) {
                    Dot(colorHex: row.project?.colorHex ?? Palette.defaultTagColor, size: 7)
                    Text(row.project?.name ?? "No project")
                        .font(Typography.rowTitle)
                        .lineLimit(1)
                    Spacer(minLength: Metrics.regular)
                    // A bar rather than a percentage: the comparison is the
                    // point, and the exact share is not a number anyone acts on.
                    Capsule()
                        .fill(Color(hex: row.project?.colorHex ?? Palette.defaultTagColor).opacity(0.45))
                        .frame(width: barWidth(row.minutes, of: maximum), height: 5)
                    Text(Format.duration(row.minutes))
                        .font(Typography.time)
                        .foregroundStyle(.secondaryText)
                        .frame(width: 58, alignment: .trailing)
                }
            }
        }
    }

    private func barWidth(_ minutes: Int, of maximum: Int) -> CGFloat {
        guard maximum > 0 else { return 0 }
        return max(3, 120 * CGFloat(minutes) / CGFloat(maximum))
    }

    private var byTask: some View {
        VStack(alignment: .leading, spacing: Metrics.regular) {
            SectionHeader(title: "By task", count: nil)
            ForEach(Array(report.byTask().prefix(12).enumerated()), id: \.offset) { _, row in
                HStack(spacing: Metrics.regular) {
                    Text(row.todo.title)
                        .font(Typography.rowTitle)
                        .lineLimit(1)
                    Spacer(minLength: Metrics.regular)
                    // Against the estimate, when there is one: this is the
                    // number that tells you whether the plan was ever realistic.
                    if let estimate = row.todo.estimateMinutes, estimate > 0 {
                        Text("est \(Format.duration(estimate))")
                            .font(Typography.rowMeta)
                            .foregroundStyle(.tertiaryText)
                    }
                    Text(Format.duration(row.minutes))
                        .font(Typography.time)
                        .foregroundStyle(.secondaryText)
                        .frame(width: 58, alignment: .trailing)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.inspectedID = row.todo.id }
            }
        }
    }

    // MARK: - Diary

    /// Day by day, in the order things happened — the part you actually read
    /// back on a Friday.
    private var diary: some View {
        VStack(alignment: .leading, spacing: Metrics.comfortable) {
            SectionHeader(title: "Day by day", count: nil)
            ForEach(report.days.reversed(), id: \.self) { day in
                VStack(alignment: .leading, spacing: Metrics.snug) {
                    HStack {
                        Text(Format.date(day))
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(Format.duration(dayMinutes(day)))
                            .font(Typography.time)
                            .foregroundStyle(.secondaryText)
                    }
                    ForEach(report.day(day)) { line in
                        entryRow(line)
                    }
                }
            }
        }
    }

    private func dayMinutes(_ day: Date) -> Int {
        report.day(day).filter { $0.entry.kind == .session }.reduce(0) { $0 + $1.minutes }
    }

    private func entryRow(_ line: TimeReport.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.regular) {
            Text(Format.time(line.entry.startedAt))
                .font(Typography.time)
                .foregroundStyle(.tertiaryText)
                .frame(width: 56, alignment: .leading)

            Image(systemName: line.entry.kind == .session ? "stopwatch" : "circle.fill")
                .font(.system(size: line.entry.kind == .session ? 9 : 5))
                .foregroundStyle(.tertiaryText)

            VStack(alignment: .leading, spacing: 1) {
                Text(line.todo.title)
                    .font(Typography.rowMeta)
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
                if !line.entry.note.isEmpty {
                    Text(line.entry.note)
                        .font(Typography.rowTitle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            if line.entry.kind == .session {
                Text(Format.duration(max(1, line.minutes)))
                    .font(Typography.time)
                    .foregroundStyle(.secondaryText)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.inspectedID = line.todo.id }
    }
}

/// The periods worth looking back over. Deliberately short: a report you have
/// to configure is one nobody opens.
enum ReportRange: String, CaseIterable, Identifiable, Hashable {
    case thisWeek, lastWeek, thisMonth, last30

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thisWeek: "This week"
        case .lastWeek: "Last week"
        case .thisMonth: "This month"
        case .last30: "30 days"
        }
    }

    func interval(now: Date, calendar: Calendar = .current) -> DateInterval {
        var weekCalendar = calendar
        weekCalendar.firstWeekday = 2   // Monday, as the calendar grid uses.
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = startOfToday.addingTimeInterval(86_400)

        switch self {
        case .thisWeek:
            let start = weekCalendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
            return DateInterval(start: start, end: endOfToday)
        case .lastWeek:
            let thisWeek = weekCalendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
            let start = calendar.date(byAdding: .day, value: -7, to: thisWeek) ?? thisWeek
            return DateInterval(start: start, end: thisWeek)
        case .thisMonth:
            let start = calendar.dateInterval(of: .month, for: now)?.start ?? startOfToday
            return DateInterval(start: start, end: endOfToday)
        case .last30:
            let start = calendar.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfToday
            return DateInterval(start: start, end: endOfToday)
        }
    }

    func subtitle(now: Date, calendar: Calendar = .current) -> String {
        let interval = self.interval(now: now, calendar: calendar)
        let last = interval.end.addingTimeInterval(-1)
        return "\(Format.date(interval.start)) – \(Format.date(last))"
    }
}
