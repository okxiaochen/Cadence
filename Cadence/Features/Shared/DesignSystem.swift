import SwiftUI

/// The visual vocabulary, in one place.
///
/// The app read as generic mostly because every value was ad hoc: a 2 here, a
/// 14 there, default controls, dividers wherever two things met. Naming a small
/// scale and using it everywhere is most of what separates a considered
/// interface from a merely functional one.
enum Metrics {
    /// A 4pt rhythm. Anything not on it looks accidental at a glance.
    static let hairline: CGFloat = 1
    static let tight: CGFloat = 4
    static let snug: CGFloat = 6
    static let regular: CGFloat = 8
    static let comfortable: CGFloat = 12
    static let loose: CGFloat = 16
    static let section: CGFloat = 24

    /// Rows sit in an inset rounded shape rather than running edge to edge, so
    /// selection reads as a card and the list keeps its margins.
    static let rowInset: CGFloat = 8
    static let rowRadius: CGFloat = 7
    static let rowPaddingVertical: CGFloat = 7
    static let rowPaddingHorizontal: CGFloat = 10

    static let controlRadius: CGFloat = 6
}

enum Typography {
    /// Titles carry the weight; everything else recedes. One clear step in
    /// size and two in colour does more than five font sizes.
    static let rowTitle = Font.system(size: 13, weight: .regular)
    static let rowMeta = Font.system(size: 11, weight: .regular)
    static let sectionHeader = Font.system(size: 11, weight: .semibold)
    static let paneTitle = Font.system(size: 15, weight: .semibold)
    static let count = Font.system(size: 11, weight: .medium).monospacedDigit()
    static let time = Font.system(size: 11, weight: .regular).monospacedDigit()
}

extension ShapeStyle where Self == Color {
    /// Text that is present but not the point.
    static var secondaryText: Color { Color(nsColor: .secondaryLabelColor) }
    /// Text that is barely there: placeholders, empty states.
    static var tertiaryText: Color { Color(nsColor: .tertiaryLabelColor) }
    /// Row hover. Deliberately weaker than selection.
    static var rowHover: Color { Color.primary.opacity(0.045) }
    /// Separators, where one is genuinely needed.
    static var hairline: Color { Color.primary.opacity(0.07) }
}

// MARK: - Checkbox

/// A round checkbox rather than AppKit's square one.
///
/// The stock `.checkbox` toggle is the single most generic element a task list
/// can have; a circle that fills is what every well-regarded task app uses, and
/// it reads as a target rather than a form control.
struct CircleCheckbox: View {
    var isOn: Bool
    var tint: Color = .accentColor
    var size: CGFloat = 15
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(
                        isOn ? tint : Color.secondaryText.opacity(isHovering ? 0.9 : 0.45),
                        lineWidth: 1.5
                    )
                    .background(Circle().fill(isOn ? tint : .clear))
                    .frame(width: size, height: size)

                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.55, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size + Metrics.snug, height: size + Metrics.snug)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isOn)
    }
}

// MARK: - Row background

/// The inset, rounded background every list row shares.
struct RowBackground: ViewModifier {
    var isSelected: Bool
    var isHovering: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Metrics.rowPaddingHorizontal)
            .padding(.vertical, Metrics.rowPaddingVertical)
            .background {
                RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                    .fill(fill)
            }
            .padding(.horizontal, Metrics.tight)
    }

    private var fill: Color {
        if isSelected { return Color.accentColor.opacity(0.16) }
        if isHovering { return .rowHover }
        return .clear
    }
}

extension View {
    func rowBackground(isSelected: Bool, isHovering: Bool) -> some View {
        modifier(RowBackground(isSelected: isSelected, isHovering: isHovering))
    }
}

// MARK: - Section header

/// Uppercase, tracked, quiet. Reads as structure rather than as content.
struct SectionHeader: View {
    var title: String
    var count: Int?
    var symbolName: String?
    var colorHex: String?

    var body: some View {
        HStack(spacing: Metrics.snug) {
            if let colorHex {
                Dot(colorHex: colorHex, size: 7)
            } else if let symbolName {
                Image(systemName: symbolName).font(.system(size: 10))
            }

            Text(title.uppercased())
                .font(Typography.sectionHeader)
                .tracking(0.6)

            Spacer(minLength: 0)

            if let count, count > 0 {
                Text("\(count)")
                    .font(Typography.count)
                    .foregroundStyle(.tertiaryText)
            }
        }
        .foregroundStyle(.secondaryText)
        .padding(.horizontal, Metrics.rowPaddingHorizontal + Metrics.tight)
        .padding(.top, Metrics.loose)
        .padding(.bottom, Metrics.snug)
    }
}
