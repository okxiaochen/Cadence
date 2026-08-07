import SwiftUI

/// Two panes with a draggable divider.
///
/// `HSplitView` draws a system divider that reads as a hard border — fine on an
/// opaque window, but on a translucent one it is the loudest thing on screen.
/// This is the same behaviour with a hairline, and a wider invisible grab area
/// so the thin line is still easy to catch.
struct PaneSplit<Leading: View, Trailing: View>: View {

    var storageKey: String
    var minimumLeading: CGFloat = 280
    var minimumTrailing: CGFloat = 420
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    @State private var width: CGFloat?
    @State private var dragStartWidth: CGFloat?
    @State private var isHovering = false

    private static var grabWidth: CGFloat { 10 }

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
    }

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
            .frame(width: Self.grabWidth)
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
