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

// MARK: - Segmented control

/// A segmented picker that does not paint an opaque chip.
///
/// AppKit's `.segmented` style draws its own bezel — a near-white capsule that
/// punches a solid hole straight through the window material, so on a
/// translucent window it is the brightest thing on screen. This says the same
/// thing with a tinted fill on the selected segment and nothing at all behind
/// the rest.
struct QuietSegmentedPicker<Value: Hashable>: View {
    var options: [(value: Value, title: String)]
    @Binding var selection: Value

    @State private var hovering: Value?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                segment(option.value, title: option.title)
            }
        }
    }

    private func segment(_ value: Value, title: String) -> some View {
        let isSelected = selection == value
        return Text(title)
            .font(.system(size: 12, weight: isSelected ? .medium : .regular))
            .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondaryText))
            .padding(.horizontal, Metrics.regular)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: Metrics.controlRadius - 1, style: .continuous)
                    .fill(fill(isSelected: isSelected, isHovering: hovering == value))
            }
            .contentShape(Rectangle())
            .onTapGesture { selection = value }
            .onHover { hovering = $0 ? value : (hovering == value ? nil : hovering) }
    }

    private func fill(isSelected: Bool, isHovering: Bool) -> Color {
        if isSelected { return Color.primary.opacity(0.09) }
        if isHovering { return .rowHover }
        return .clear
    }
}

// MARK: - Quiet controls

/// Controls for a translucent surface.
///
/// Every stock AppKit control — a popup button, a stepper field, a bordered
/// button, a `.roundedBorder` text field — paints its own near-white bezel.
/// On a window whose whole point is that it is not opaque, each one is a solid
/// chip punched through the material, and a form full of them is the brightest
/// thing on screen. These say the same things with a tinted fill and nothing
/// else, and put the actual editing widget inside a popover, which is its own
/// surface and may be as opaque as it likes.
struct QuietButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: prominent ? .medium : .regular))
            .foregroundStyle(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            .padding(.horizontal, Metrics.regular)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                    .fill(fill(pressed: configuration.isPressed))
            }
            .contentShape(Rectangle())
    }

    private func fill(pressed: Bool) -> Color {
        let base = prominent ? Color.accentColor : Color.primary
        return base.opacity(pressed ? 0.22 : (prominent ? 0.14 : 0.07))
    }
}

extension ButtonStyle where Self == QuietButtonStyle {
    /// A button that reads as a target without becoming a filled chip.
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
    /// The one action a panel is actually for.
    static var quietProminent: QuietButtonStyle { QuietButtonStyle(prominent: true) }
}

/// The icon affordances beside a field: no bezel, but a hit target and a hover
/// that says the pointer found them.
struct QuietIconButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(3)
            .background {
                RoundedRectangle(cornerRadius: Metrics.tight, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12
                                                : (isHovering ? 0.06 : 0)))
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

/// A popup button with no bezel: the value, a chevron, and a menu.
struct QuietMenuPicker<Value: Hashable>: View {
    var options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: Metrics.tight) {
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondaryText)
            }
            .padding(.horizontal, Metrics.snug)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var title: String {
        options.first { $0.value == selection }?.title ?? ""
    }
}

/// A date shown as text; editing it happens in a popover.
struct QuietDateField: View {
    @Binding var date: Date
    /// Whether the time of day is part of this value.
    var includesTime: Bool = false
    /// Show only the time — for a field that sits beside a separate day field.
    var timeOnly: Bool = false

    @State private var isEditing = false

    var body: some View {
        Button { isEditing = true } label: {
            Text(label).monospacedDigit()
        }
        .buttonStyle(.quiet)
        .popover(isPresented: $isEditing) {
            editor.padding(Metrics.comfortable)
        }
    }

    /// Inside a popover the stock pickers are fine: a popover is a surface of
    /// its own, not a hole in the window. The two styles are different types,
    /// so they cannot be chosen with a ternary.
    @ViewBuilder
    private var editor: some View {
        if timeOnly {
            DatePicker("", selection: $date, displayedComponents: [.hourAndMinute])
                .datePickerStyle(.stepperField)
                .labelsHidden()
        } else {
            DatePicker(
                "",
                selection: $date,
                displayedComponents: includesTime ? [.date, .hourAndMinute] : [.date]
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
        }
    }

    private var label: String {
        if timeOnly { return Format.time(date) }
        return includesTime ? Format.dateTime(date) : Format.date(date)
    }
}

/// A text field with a fill instead of a bezel.
struct QuietFieldStyle: ViewModifier {
    var width: CGFloat?

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, Metrics.snug)
            .padding(.vertical, 3)
            .frame(width: width, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
    }
}

extension View {
    func quietField(width: CGFloat? = nil) -> some View {
        modifier(QuietFieldStyle(width: width))
    }

    /// A borderless icon button — the small clear/toggle affordances that sit
    /// beside a field and should never look like buttons in their own right,
    /// but should still answer the pointer.
    func quietIconButton() -> some View {
        buttonStyle(QuietIconButtonStyle())
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
