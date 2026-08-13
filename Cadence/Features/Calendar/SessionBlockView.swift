import SwiftUI

/// One recorded session on the grid — time that was actually spent, as against
/// the block that planned it.
///
/// Drawn deliberately unlike `BlockView`: a dashed edge and a lighter fill. The
/// two sit side by side in the same layout precisely so the difference between
/// plan and record can be read without a legend.
struct SessionBlockView: View {
    var session: TrackedSession
    var interval: DateInterval
    var height: CGFloat

    /// Short sessions are given a floor so the title has somewhere to go: a
    /// ten-minute record four points tall says something happened and refuses
    /// to say what, which is the one thing it exists to answer.
    static let minimumHeight: CGFloat = 22

    private static let radius: CGFloat = 5

    private var color: Color { Color(hex: session.colorHex) }
    private var isRunning: Bool { session.entry.isRunning }

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.tight) {
            Image(systemName: isRunning ? "stopwatch.fill" : "stopwatch")
                .font(.system(size: 9))
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.todo.title)
                    .font(.system(size: 11))
                    .foregroundStyle(color.textOnTint)
                    .lineLimit(height >= 46 ? 2 : 1)
                if height >= 34 {
                    Text("\(Format.time(interval.start))–\(isRunning ? "now" : Format.time(interval.end))"
                         + " · \(Format.duration(max(1, Int(interval.duration / 60))))")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.snug)
        .padding(.vertical, 2)
        .frame(height: height, alignment: .topLeading)
        // `.frame` proposes a size, it does not clip: a two-line title in a
        // short session would draw straight over the entry below it.
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .fill(color.opacity(isRunning ? 0.2 : 0.12))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(
                    color.opacity(isRunning ? 0.9 : 0.45),
                    style: StrokeStyle(
                        lineWidth: isRunning ? 1.5 : 1,
                        dash: isRunning ? [] : [3, 2]
                    )
                )
        }
        .help(tooltip)
    }

    private var tooltip: String {
        let range = "\(Format.time(interval.start))–\(Format.time(interval.end))"
        let duration = Format.duration(max(1, Int(interval.duration / 60)))
        let head = isRunning ? "\(session.todo.title) — timing now" : session.todo.title
        let note = session.entry.note.isEmpty ? "" : "\n\(session.entry.note)"
        return "\(head)\nTracked \(range) · \(duration)\(note)"
    }
}
