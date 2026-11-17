import AppKit
import SwiftUI

enum PanelSection: String, CaseIterable, Identifiable {
    case output = "Output", input = "Input", nowPlaying = "Now Playing", applications = "Applications"
    var id: String { rawValue }
}

/// UI state of the open panel. There is one highlight for the whole panel, set
/// by the mouse and by the arrow keys alike, so two rows can never be lit at once.
@MainActor @Observable
final class PanelState {
    var highlighted: String?
    var openSections: Set<PanelSection> = [.output, .nowPlaying, .applications]
    /// "app:<key>" or "np:<key>" for the row whose controls are showing.
    var expandedRow: String?
    /// UID of the output whose listening modes are showing.
    var expandedDevice: String?
    /// App whose equalizer popover is showing.
    var eqTarget: String?
    /// Highlightable rows in on-screen order, for keyboard navigation.
    @ObservationIgnored var rows: [MenuRowEntry] = []

    @ObservationIgnored var close: () -> Void = {}
    @ObservationIgnored var openSettings: () -> Void = {}

    /// Where the mouse was when the highlight last followed it. Rows that slide
    /// under a still cursor during an animation don't take the highlight; like a
    /// native menu, only a real mouse move does.
    @ObservationIgnored private var lastMouse: CGPoint?

    func hover(_ id: String, active: Bool) {
        let mouse = NSEvent.mouseLocation
        guard mouse != lastMouse else { return }
        if active {
            lastMouse = mouse
            if highlighted != id { highlighted = id }
        } else if highlighted == id {
            highlighted = nil
        }
    }

    func reset() {
        lastMouse = nil
        highlighted = nil
        eqTarget = nil
    }

    func toggle(_ section: PanelSection) {
        Motion.animate {
            if openSections.contains(section) { openSections.remove(section) } else { openSections.insert(section) }
        }
    }

    func toggleRow(_ id: String) {
        Motion.animate {
            expandedRow = expandedRow == id ? nil : id
            eqTarget = nil
        }
    }

    // MARK: Keyboard

    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == highlighted }
        let next = index.map { min(max($0 + delta, 0), rows.count - 1) } ?? (delta > 0 ? 0 : rows.count - 1)
        highlighted = rows[next].id
    }

    func activate() { current?.action() }

    /// Right opens the highlighted row's section or controls, left closes them.
    func expand(_ open: Bool) { current?.expand?(open) }

    private var current: MenuRowEntry? { rows.first { $0.id == highlighted } }
}

struct MenuRowEntry: Equatable, @unchecked Sendable {
    let id: String
    let action: @MainActor () -> Void
    var expand: (@MainActor (Bool) -> Void)?
    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

struct MenuRowsKey: PreferenceKey {
    static let defaultValue: [MenuRowEntry] = []
    static func reduce(value: inout [MenuRowEntry], nextValue: () -> [MenuRowEntry]) { value += nextValue() }
}

private struct MenuHighlightedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside the highlighted row, where text and glyphs turn white.
    var menuHighlighted: Bool {
        get { self[MenuHighlightedKey.self] }
        set { self[MenuHighlightedKey.self] = newValue }
    }
}

/// A clickable row that highlights like a native menu item: accent fill inset
/// from the panel edge, white text, one row at a time.
struct MenuRow: ViewModifier {
    @Environment(PanelState.self) private var panel
    let id: String
    var height: CGFloat? = Metrics.rowHeight
    var expand: (@MainActor (Bool) -> Void)?
    let action: @MainActor () -> Void

    func body(content: Content) -> some View {
        let lit = panel.highlighted == id
        content
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .padding(.horizontal, Metrics.inset)
            .foregroundStyle(lit ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .environment(\.menuHighlighted, lit)
            .background {
                if lit {
                    RoundedRectangle(cornerRadius: Metrics.highlightRadius, style: .continuous)
                        .fill(Color(nsColor: .controlAccentColor))
                        .padding(.horizontal, Metrics.highlightInset)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active = phase { panel.hover(id, active: true) } else { panel.hover(id, active: false) }
            }
            .onTapGesture { action() }
            .preference(key: MenuRowsKey.self, value: [MenuRowEntry(id: id, action: action, expand: expand)])
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

extension View {
    func menuRow(_ id: String, height: CGFloat? = Metrics.rowHeight, expand: (@MainActor (Bool) -> Void)? = nil,
                 action: @escaping @MainActor () -> Void) -> some View {
        modifier(MenuRow(id: id, height: height, expand: expand, action: action))
    }
}

/// NSMenu's separator: a 1 pt line with the text inset, 10 pt tall.
struct MenuSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.13))
            .frame(height: 1)
            .padding(.horizontal, Metrics.inset)
            .padding(.vertical, 4.5)
            .accessibilityHidden(true)
    }
}

/// Grey bold title like an NSMenu section header, with a chevron that opens and closes the section.
struct SectionHeader: View {
    @Environment(PanelState.self) private var panel
    let section: PanelSection

    var body: some View {
        let open = panel.openSections.contains(section)
        HStack {
            Text(section.rawValue)
                .font(.system(size: NSFont.smallSystemFontSize, weight: .semibold))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .rotationEffect(.degrees(open ? 90 : 0))
        }
        .modifier(HeaderTint())
        .menuRow("section:\(section.rawValue)", height: 22,
                 expand: { if $0 != panel.openSections.contains(section) { panel.toggle(section) } }) {
            panel.toggle(section)
        }
        .accessibilityLabel(section.rawValue)
        .accessibilityValue(open ? "expanded" : "collapsed")
        // NSMenu puts a header's text 20 pt below the separator line.
        .padding(.top, 4)
    }
}

/// Section header grey, white while highlighted.
private struct HeaderTint: ViewModifier {
    @Environment(\.menuHighlighted) private var lit
    func body(content: Content) -> some View {
        content.foregroundStyle(lit ? AnyShapeStyle(Color.white) : AnyShapeStyle(.tertiary))
    }
}

/// Greyed-out text, such as "Not Playing".
struct PlaceholderRow: View {
    let text: String
    var body: some View {
        Text(text)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Metrics.inset)
            .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
    }
}

/// The menu window's surface. On macOS 26 and later a native menu sits on an
/// NSGlassEffectView with a 12 pt radius and no tint, and so does the panel.
/// Before that it's the menu material with a hairline rim and a shadow.
struct PanelSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            content.background(MenuGlass())
        } else {
            content
                .background(MenuMaterial().clipShape(shape).shadow(color: .black.opacity(0.3), radius: 18, y: 10))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
        }
    }
}

@available(macOS 26, *)
private struct MenuGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.cornerRadius = Metrics.cornerRadius
        view.style = .regular
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {}
}

/// NSMenu's material before Liquid Glass.
private struct MenuMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
