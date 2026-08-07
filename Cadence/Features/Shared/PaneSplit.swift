import SwiftUI

/// Two panes with a draggable divider.
///
/// `HSplitView` draws a system divider that reads as a hard border — fine on an
/// opaque window, but on a translucent one it is the loudest thing on screen.
/// This is the same behaviour with a hairline, and a wider invisible grab area
/// so the thin line is still easy to catch.
/// Kept out of `PaneSplit` itself: a generic type cannot hold stored statics,
/// and a window sizing itself around a split should not have to name the split's
/// two view types to ask how narrow it may be.
enum PaneSplitMetrics {
    static let minimumLeading: CGFloat = 280
    static let minimumTrailing: CGFloat = 420
    static let grabWidth: CGFloat = 10

    /// What an unconfigured split needs, in total.
    static var minimumWidth: CGFloat { minimumLeading + grabWidth + minimumTrailing }
}

struct PaneSplit<Leading: View, Trailing: View>: View {

    var storageKey: String
    var minimumLeading: CGFloat = PaneSplitMetrics.minimumLeading
    var minimumTrailing: CGFloat = PaneSplitMetrics.minimumTrailing
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    @State private var width: CGFloat?
    @State private var dragStartWidth: CGFloat?
    @State private var isHovering = false

    var body: some View {
        GeometryReader { proxy in
            let resolved = resolvedWidth(in: proxy.size.width)

            HStack(spacing: 0) {
                leading.frame(width: resolved)
                divider(totalWidth: proxy.size.width)
                trailing.frame(maxWidth: .infinity)
            }
            .onAppear {
                if width == nil {
                    let stored = UserDefaults.standard.double(forKey: storageKey)
                    width = stored > 0 ? stored : proxy.size.width * 0.42
                }
            }
        }
        // A `GeometryReader` accepts any width it is offered and reports no
        // minimum of its own, so without this the split claims it can be a
        // hairline wide. A parent `HStack` believes it, hands the space to
        // whatever is beside it — the assistant — and the two panes end up with
        // overlapping frames, drawing on top of each other.
        .frame(minWidth: minimumWidth)
    }

    /// What the two panes and the divider actually need. `resolvedWidth`
    /// enforces this internally; this is the same number, said out loud.
    var minimumWidth: CGFloat { minimumLeading + PaneSplitMetrics.grabWidth + minimumTrailing }

    private func resolvedWidth(in total: CGFloat) -> CGFloat {
        let proposed = width ?? total * 0.42
        let maximum = max(minimumLeading, total - minimumTrailing)
        return min(max(proposed, minimumLeading), maximum)
    }

    private func divider(totalWidth: CGFloat) -> some View {
        Rectangle()
            .fill(.hairline)
            .frame(width: 1)
            // The line stays a hairline; the target around it does not.
            .frame(width: PaneSplitMetrics.grabWidth)
            .contentShape(Rectangle())
            .onHover { inside in
                isHovering = inside
                CursorStack.shared.setColumnResize(inside)
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStartWidth ?? resolvedWidth(in: totalWidth)
                        if dragStartWidth == nil { dragStartWidth = start }
                        let maximum = max(minimumLeading, totalWidth - minimumTrailing)
                        width = min(max(start + value.translation.width, minimumLeading), maximum)
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        if let width { UserDefaults.standard.set(width, forKey: storageKey) }
                    }
            )
    }
}
