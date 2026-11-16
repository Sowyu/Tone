import AppKit
import SwiftUI

enum Motion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// The one spring every animation uses. Reduce Motion swaps it for a short fade.
    static var spring: Animation { reduce ? .easeInOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.86) }

    static func animate(_ body: () -> Void) { withAnimation(spring, body) }
}

/// Measured from the concept video (2x frames, values in points).
enum Metrics {
    static let width: CGFloat = 308
    static let cornerRadius: CGFloat = 16
    static let inset: CGFloat = 14          // text and separator inset
    // Measured from the system Sound menu: 32 pt rows, 4.5 pt inset, 9 pt continuous corners, 9% fill.
    static let highlightInset: CGFloat = 4.5
    static let highlightRadius: CGFloat = 9
    static let rowHeight: CGFloat = 32
    static let artwork: CGFloat = 40
    static let appIcon: CGFloat = 18
}

/// The panel surface: Liquid Glass on macOS 26+, menu material before that.
struct PanelSurface: ViewModifier {
    var radius: CGFloat = Metrics.cornerRadius

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(VisualEffectBackground())
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// True while the user moves around with the keyboard. Focus highlights only
/// show then, so a click never leaves a second highlight behind.
@MainActor @Observable
final class KeyboardMode {
    static let shared = KeyboardMode()
    var active = false
}

/// Rounded hover highlight inset from the panel edge, like menu items.
struct HoverHighlight: ViewModifier {
    var focused: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: Metrics.highlightRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.09))
                    .padding(.horizontal, Metrics.highlightInset)
                    .opacity(hovering || (focused && KeyboardMode.shared.active) ? 1 : 0)
            }
            .onHover { hovering = $0 }
    }
}

extension View {
    func panelSurface(radius: CGFloat = Metrics.cornerRadius) -> some View { modifier(PanelSurface(radius: radius)) }
    func hoverHighlight(focused: Bool = false) -> some View { modifier(HoverHighlight(focused: focused)) }

    /// Tab-focusable row: Return or Space runs `action`.
    func focusRow(_ focused: FocusState<Bool>.Binding, action: @escaping () -> Void) -> some View {
        focusable()
            .focused(focused)
            .focusEffectDisabled()
            .onKeyPress(.return) { action(); return .handled }
            .onKeyPress(.space) { action(); return .handled }
    }
}

/// Separator inset like the ones between sections.
struct InsetDivider: View {
    var inset: CGFloat = Metrics.inset
    var body: some View { Divider().padding(.horizontal, inset) }
}

extension Double {
    /// "+11.3" / "−1.1" with a real minus sign.
    var signedDB: String {
        if abs(self) < 0.05 { return "0.0" }
        return (self > 0 ? "+" : "\u{2212}") + String(format: "%.1f", abs(self))
    }

    var percent: String { "\(Int((self * 100).rounded()))%" }
}

enum SpeakerSymbol {
    static func name(volume: Double, muted: Bool) -> String {
        if muted || volume <= 0.001 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
