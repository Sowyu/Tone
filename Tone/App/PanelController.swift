import AppKit
import SwiftUI

/// Borderless panel that can take keyboard focus without activating Tone.
final class TonePanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Status item + the popover-style panel under it.
///
/// The panel is a transparent window as tall as the screen so the glass surface
/// inside can grow and shrink with a spring, like the system menu bar extras.
/// Transparent areas let clicks through, and a global mouse monitor closes the
/// panel when you click anywhere else. The EQ is a native popover off this panel.
@MainActor
final class PanelController: NSObject {
    static let margin: CGFloat = 24

    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: TonePanel
    private var clickMonitor: Any?

    init(model: AppModel, openSettings: @escaping () -> Void) {
        self.model = model
        panel = TonePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.onEscape = { [weak self] in self?.close() }

        let root = PopoverRoot(onSettings: openSettings, onClose: { [weak self] in self?.close() })
            .environment(model)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Tone")
        }
        updateIcon()
    }

    // MARK: Icon

    private func updateIcon() {
        withObservationTracking {
            let style = model.store.state.iconStyle
            let volume = model.devices.masterVolume
            let muted = model.devices.isMuted
            let name: String = switch style {
            case .speaker: SpeakerSymbol.name(volume: Double(volume), muted: muted)
            case .slider: "slider.horizontal.3"
            case .waveform: "waveform"
            }
            let image = NSImage(systemSymbolName: name, accessibilityDescription: "Tone")
            image?.isTemplate = true
            statusItem.button?.image = image
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateIcon() } }
        }
    }

    // MARK: Showing

    @objc private func toggle() {
        panel.isVisible ? close() : show()
    }

    func toggleFromDebug() { toggle() }

    /// Debug only: expand a row ("app:<key>" or "np:<key>") and optionally show its EQ.
    func expandFromDebug(row: String, eq: Bool) {
        if !panel.isVisible { show() }
        let key = String(row.drop(while: { $0 != ":" }).dropFirst())
        Motion.animate {
            model.openSections.formUnion([.nowPlaying, .applications])
            model.expandedRow = row
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { self.model.eqTarget = eq ? key : nil }
        }
    }

    func show() {
        guard let button = statusItem.button, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let rect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        let width = Self.margin + Metrics.width + Self.margin
        let top = min(rect.minY, visible.maxY) - 2
        let height = top - visible.minY
        var popoverX = rect.midX - Metrics.width / 2
        popoverX = min(popoverX, visible.maxX - Metrics.width - 6)
        popoverX = max(popoverX, visible.minX + 6)
        let originX = popoverX - Self.margin
        panel.setFrame(NSRect(x: originX, y: top - height, width: width, height: height), display: true)

        if model.permission.status != .authorized { model.permission.refresh() }
        model.isPanelOpen = true
        panel.orderFrontRegardless()
        panel.makeKey()
        // Don't start with a focus ring on the first row; Tab moves into the rows.
        DispatchQueue.main.async { MainActor.assumeIsolated { _ = self.panel.makeFirstResponder(nil) } }
        button.highlight(true)

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        guard panel.isVisible else { return }
        AudioEngine.log.info("Panel close")
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        model.isPanelOpen = false
        model.eqTarget = nil
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
    }
}
