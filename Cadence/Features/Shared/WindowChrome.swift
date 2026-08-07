import AppKit
import SwiftUI

/// Blurred desktop behind the window.
///
/// `.behindWindow` blending is what produces the frosted look — the material
/// samples what is actually behind the window, so it only works once the window
/// itself is non-opaque (see `TranslucentWindow`).
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Makes the hosting window non-opaque so the material above can see through it.
///
/// A SwiftUI `Window` has no API for this, so the window is reached through the
/// view hierarchy. Harmless when translucency is off — the flags are simply set
/// back.
private struct TranslucentWindow: NSViewRepresentable {
    var isTranslucent: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: NSView) {
        // The window is nil during the first layout pass.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = !isTranslucent
            window.backgroundColor = isTranslucent ? .clear : .windowBackgroundColor
        }
    }
}

/// Makes the split view's sidebar column use the same material as the rest of
/// the window.
///
/// AppKit gives that column its own `NSVisualEffectView` with the `.sidebar`
/// material, which sits *below* the SwiftUI `List` — so hiding the list's own
/// background does not reach it, and the sidebar stays a different shade from
/// everything beside it. The only way to it is up the view hierarchy.
private struct MatchSidebarMaterial: NSViewRepresentable {
    var appearance: BackgroundAppearance

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        apply(from: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(from: view)
    }

    private func apply(from view: NSView) {
        // The hierarchy does not exist during the first layout pass.
        DispatchQueue.main.async {
            var ancestor = view.superview
            while let current = ancestor {
                if let effect = current as? NSVisualEffectView {
                    effect.material = appearance.material
                    // Never pin an appearance: inheriting from the window is
                    // what keeps light and dark mode working.
                    effect.appearance = nil
                    // Otherwise the sidebar dims when the window loses focus
                    // and the mismatch is back whenever the app is not front.
                    effect.state = .active
                    return
                }
                ancestor = current.superview
            }
        }
    }
}

extension View {
    /// Gives the sidebar exactly the treatment the window gets: the same
    /// material, and the same wash of window colour over it.
    ///
    /// Setting only the material left the sidebar showing far more of the
    /// desktop than the rest of the window, because the wash is what most of
    /// the opacity comes from. The material is *covered* rather than hidden —
    /// hiding an `NSVisualEffectView` takes its whole subtree with it, and the
    /// sidebar's list is one of its subviews.
    func matchesWindowMaterial(_ appearance: BackgroundAppearance) -> some View {
        background {
            Color(nsColor: .windowBackgroundColor)
                .opacity(appearance.isTranslucent ? appearance.washOpacity : 1)
                .ignoresSafeArea()
        }
        .background(MatchSidebarMaterial(appearance: appearance))
    }
}

// MARK: - The modifier views use

extension View {
    /// Applies the user's chosen background: a solid colour, or a frosted
    /// material with an adjustable amount of solid colour laid over it.
    func windowBackground(_ appearance: BackgroundAppearance) -> some View {
        background {
            ZStack {
                if appearance.isTranslucent {
                    VisualEffectBackground(material: appearance.material)
                    // The wash is what makes the slider mean something: at full
                    // opacity the frost is invisible, at zero it is pure glass.
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(appearance.washOpacity)
                } else {
                    Color(nsColor: .windowBackgroundColor)
                }
            }
            .ignoresSafeArea()
        }
        .background(TranslucentWindow(isTranslucent: appearance.isTranslucent))
    }
}

/// What the window looks like behind its content.
struct BackgroundAppearance: Equatable {
    var style: BackgroundStyle
    /// 0 = clear glass, 1 = solid. Only meaningful when translucent.
    var opacity: Double

    var isTranslucent: Bool { style != .solid }

    var material: NSVisualEffectView.Material {
        switch style {
        case .solid: .windowBackground
        case .frosted: .underWindowBackground
        case .vibrant: .sidebar
        // Not `.hudWindow`: that one forces a dark appearance whatever the
        // system is set to, and it is applied to views we do not own.
        case .glass: .fullScreenUI
        }
    }

    /// Never fully clear: text over a bare desktop is unreadable, so the slider
    /// bottoms out at a thin wash rather than at nothing.
    var washOpacity: Double {
        let amount = min(1, max(0, opacity))
        return 0.12 + amount * 0.88
    }
}

enum BackgroundStyle: String, CaseIterable, Identifiable {
    case solid, frosted, vibrant, glass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .solid: "Solid"
        case .frosted: "Frosted"
        case .vibrant: "Vibrant"
        case .glass: "Glass"
        }
    }
}

private extension Double {
    func clamped() -> Double { min(1, max(0, self)) }
}

/// Quietens the divider AppKit draws between the split view's columns.
///
/// `NSSplitView` paints it itself and exposes no colour, so the only lever is
/// the style. `.thin` is a hairline that takes the window's separator colour,
/// which is far less assertive than the default once the two sides share a
/// background.
struct QuietSplitDivider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        apply(from: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(from: view)
    }

    private func apply(from view: NSView) {
        DispatchQueue.main.async {
            var ancestor = view.superview
            while let current = ancestor {
                if let split = current as? NSSplitView {
                    split.dividerStyle = .thin
                    return
                }
                ancestor = current.superview
            }
        }
    }
}

// MARK: - Light / dark

/// Whether the app follows the system appearance or pins one.
///
/// Applied to `NSApp` rather than to a view: a SwiftUI `.preferredColorScheme`
/// reaches the view tree but leaves the titlebar, menus and every panel we open
/// on the system setting, which looks broken rather than deliberate.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    func apply() {
        NSApp.appearance = nsAppearance
    }
}
