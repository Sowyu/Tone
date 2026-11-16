import AppKit
import SwiftUI

enum Motion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// The one spring every animation uses. Reduce Motion swaps it for a short fade.
    static var spring: Animation { reduce ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.82) }

    static func animate(_ body: () -> Void) { withAnimation(spring, body) }
}

enum SpeakerSymbol {
    static func name(volume: Double, muted: Bool) -> String {
        if muted || volume <= 0.001 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

/// NSVisualEffectView with a rounded mask; follows the active state of the panel.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var cornerRadius: CGFloat = 16

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.mask(radius: cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }

    static func mask(radius: CGFloat) -> NSImage {
        let size = NSSize(width: radius * 2 + 1, height: radius * 2 + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// The translucent rounded card used by the popover and the EQ panel.
struct PanelCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(VisualEffectBackground())
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
    }
}

/// Rounded hover/focus highlight for clickable rows.
struct RowHighlight: ViewModifier {
    var active: Bool
    var focused: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(hovering || focused ? 0.1 : (active ? 0.06 : 0)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.blue.opacity(focused ? 0.8 : 0), lineWidth: 1.5)
            )
            .onHover { hovering = $0 }
    }
}

extension View {
    func panelCard() -> some View { modifier(PanelCard()) }
    func rowHighlight(active: Bool = false, focused: Bool = false) -> some View {
        modifier(RowHighlight(active: active, focused: focused))
    }
}

extension Double {
    /// "+11.3" / "−1.1" with a real minus sign.
    var signedDB: String {
        let s = String(format: "%.1f", abs(self))
        if abs(self) < 0.05 { return "0.0" }
        return (self > 0 ? "+" : "\u{2212}") + s
    }
}

extension View {
    /// Tab-focusable row: Return or Space runs `action`.
    func focusRow(_ focused: FocusState<Bool>.Binding, action: @escaping () -> Void) -> some View {
        focusable()
            .focused(focused)
            .focusEffectDisabled()
            .onKeyPress(.return) { action(); return .handled }
            .onKeyPress(.space) { action(); return .handled }
    }
}
