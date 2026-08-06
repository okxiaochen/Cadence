import SwiftUI

extension Color {
    /// `#RRGGBB` / `#RRGGBBAA`. Falls back to gray on anything unparseable so a
    /// bad stored value can never crash the list.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        var value: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&value) else {
            self = .gray
            return
        }
        let r, g, b, a: Double
        switch cleaned.count {
        case 6:
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
            a = 1
        case 8:
            r = Double((value & 0xFF000000) >> 24) / 255
            g = Double((value & 0x00FF0000) >> 16) / 255
            b = Double((value & 0x0000FF00) >> 8) / 255
            a = Double(value & 0x000000FF) / 255
        default:
            self = .gray
            return
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

/// A small colored dot — projects in the sidebar, tags on a row.
struct Dot: View {
    var colorHex: String
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(Color(hex: colorHex))
            .frame(width: size, height: size)
    }
}

struct TagChip: View {
    var tag: Tag

    var body: some View {
        Text(tag.name)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color(hex: tag.colorHex).opacity(0.18), in: Capsule())
            .foregroundStyle(Color(hex: tag.colorHex))
    }
}

/// Due-date badge that turns red once overdue.
struct DueBadge: View {
    var date: Date
    var isCompleted: Bool

    var body: some View {
        let overdue = !isCompleted && date < Calendar.current.startOfDay(for: Date())
        Label(Format.relativeDue(date), systemImage: "calendar")
            .font(.caption)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(overdue ? Color.red : .secondary)
    }
}
