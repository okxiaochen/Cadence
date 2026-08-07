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
        case .glass: .hudWindow
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
