import SwiftUI

/// One task block on the grid.
struct BlockView: View {
    var block: ScheduledBlock
    var interval: DateInterval
    /// The height actually available, so the label can decide how much to show
    /// rather than overflowing and covering its neighbour.
    var height: CGFloat
    var isSelected: Bool
    var isDragging: Bool
    var conflicts: Bool

    static let radius: CGFloat = 6

    private var color: Color { Color(hex: block.colorHex) }
    private var isCompleted: Bool { block.todo.isCompleted }

    var body: some View {
        HStack(spacing: 0) {
            // Part of the rounded shape rather than a stripe laid on top, so
            // the corner does not show a square notch.
            UnevenRoundedRectangle(
                topLeadingRadius: Self.radius,
                bottomLeadingRadius: Self.radius
            )
            .fill(color.opacity(isCompleted ? 0.35 : 0.9))
            .frame(width: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text(block.todo.title)
                    .font(.system(size: 11, weight: .medium))
                    .strikethrough(isCompleted)
                    .foregroundStyle(isCompleted ? AnyShapeStyle(.secondaryText)
                                                 : AnyShapeStyle(color.textOnTint))
                    .lineLimit(titleLines)
                    .truncationMode(.tail)
                if showsTimeRange {
                    Text("\(Format.time(interval.start))–\(Format.time(interval.end))")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondaryText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Metrics.snug)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: height, alignment: .top)
        // Hard stop: nothing may draw outside the block's own time slot.
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .fill(color.opacity(isCompleted ? 0.07 : 0.16))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isSelected ? 1.5 : 0.5)
        }
        .opacity(isDragging ? 0.85 : 1)
        .shadow(color: .black.opacity(isDragging ? 0.22 : 0), radius: 8, y: 3)
        .overlay(alignment: .topTrailing) {
            if conflicts && !isDragging {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
                    .padding(3)
                    .help("Overlaps another block or a calendar event")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // While dragging, the readout matters more than the title —
            // it is the only way to see what you are resizing to.
            if isDragging {
                Text(Format.duration(durationMinutes))
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 3))
                    .padding(3)
            }
        }
        .help("\(block.todo.title)\n\(Format.time(interval.start))–\(Format.time(interval.end))")
    }

    /// Driven by available points, not by duration: the same 30-minute block is
    /// roomy zoomed in and a sliver zoomed out.
    private var showsTimeRange: Bool { height >= 34 }

    private var titleLines: Int {
        switch height {
        case ..<26: 1
        case ..<52: 2
        default: 3
        }
    }

    private var durationMinutes: Int { Int((interval.duration / 60).rounded()) }

    private var borderColor: Color {
        if isSelected { return color }
        if conflicts { return .orange.opacity(0.6) }
        return color.opacity(0.3)
    }
}
