import AppKit
import SwiftUI

/// Ported from VectorScroll's SettingsStyle so both apps' settings look the same.
/// The colors, metrics and window setup match it; the groups and rows are SwiftUI.
@MainActor
enum SettingsStyle {
    // Groups share the window color and only a light edge separates them.
    static let background = NSColor(name: "SettingsBackground", dynamicProvider: { (appearance: NSAppearance) -> NSColor in
        NSColor(white: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 40 / 255 : 236 / 255, alpha: 1)
    })
    static let groupFill = NSColor(name: "SettingsGroupFill", dynamicProvider: { (appearance: NSAppearance) -> NSColor in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.04) : NSColor.white.withAlphaComponent(0.7)
    })

    // Menu bar apps can't count on activation. Bring the window to the current
    // Space, including over full-screen apps, and front it even if macOS declines.
    static func present(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    static func prepareWindow(_ window: NSWindow) {
        window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        // No visible title bar. The title stays for the Window menu and VoiceOver.
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isOpaque = true
        window.backgroundColor = background
    }
}

@MainActor
final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w":
                performClose(nil)
                return true
            case "q":
                NSApp.terminate(nil)
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// A small heading with an SF Symbol above a rounded group of rows.
struct SettingsSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                // A fixed slot keeps every heading's text on the same line, whatever the symbol's width.
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        if row.id != rows.first?.id { Divider() }
                        row
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: SettingsStyle.groupFill), in: .rect(cornerRadius: 10))
        }
    }
}

/// A label, an optional secondary description, and a control on the trailing edge.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail { SettingsFootnote(text: detail) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control.fixedSize()
        }
        .padding(.vertical, 9)
    }
}

struct SettingsFootnote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// VectorScroll's action button: medium weight, leading symbol, glass on macOS 26 and later.
    @ViewBuilder func settingsAction() -> some View {
        let styled = font(.system(size: 13, weight: .medium)).labelStyle(.titleAndIcon)
        #if compiler(>=6.2)
        if #available(macOS 26, *) { styled.buttonStyle(.glass) } else { styled.buttonStyle(.bordered) }
        #else
        styled.buttonStyle(.bordered)
        #endif
    }
}
