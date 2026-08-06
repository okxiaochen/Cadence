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

    private var color: Color { Color(hex: block.colorHex) }
    private var isCompleted: Bool { block.todo.isCompleted }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(color)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text(block.todo.title)
                    .font(.caption.weight(.medium))
                    .strikethrough(isCompleted)
                    .lineLimit(titleLines)
                    .truncationMode(.tail)
                if showsTimeRange {
                    Text("\(Format.time(interval.start))–\(Format.time(interval.end))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: height, alignment: .top)
        // Hard stop: nothing may draw outside the block's own time slot.
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .background(color.opacity(isCompleted ? 0.10 : 0.22), in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(borderColor, lineWidth: isSelected ? 2 : 1)
        }
        .opacity(isDragging ? 0.85 : 1)
        .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: 6, y: 2)
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
        return color.opacity(0.45)
    }
}
