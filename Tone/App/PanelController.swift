import AppKit
import SwiftUI

/// Borderless panel that takes key focus without activating Tone.
final class TonePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// The shadow margin reaches above the menu bar; don't let AppKit push the window down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The status item and the menu-style panel under it.
///
/// The panel is a transparent window as tall as the screen, so the surface inside
/// can spring to its new height when a section or row expands. Clicks on the
/// transparent part fall through to whatever is below, and a click anywhere
/// outside Tone closes the panel, as with a menu.
@MainActor
final class PanelController: NSObject {
    private let model: AppModel
    private let state = PanelState()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel = TonePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: true)
    private var monitors: [Any] = []

    init(model: AppModel, openSettings: @escaping () -> Void) {
        self.model = model
        super.init()
        state.close = { [weak self] in self?.close() }
        state.openSettings = { [weak self] in
            self?.close()
            openSettings()
        }

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        let hosting = NSHostingView(rootView: PanelRoot().environment(model).environment(state))
        hosting.sizingOptions = []
        panel.contentView = hosting

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.setAccessibilityLabel("Tone")
        }
        updateIcon()
    }

    private func updateIcon() {
        withObservationTracking {
            let name = switch model.store.state.iconStyle {
            case .speaker: SpeakerSymbol.name(volume: Double(model.devices.masterVolume), muted: model.devices.isMuted)
            case .slider, .waveform: model.store.state.iconStyle.symbol
            }
            statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Tone")
        } onChange: { [weak self] in
            MainLoop.perform { self?.updateIcon() }
        }
    }

    // MARK: Showing

    @objc func toggle() {
        panel.isVisible ? close() : show()
    }

    func show() {
        guard let button = statusItem.button, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let item = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        let margin = Metrics.shadowMargin
        // Left edge under the status item like a status item's menu, kept on screen.
        var x = item.minX
        x = min(x, visible.maxX - Metrics.width - 6)
        x = max(x, visible.minX + 6)
        let top = min(item.minY, visible.maxY) - 5 + margin
        panel.setFrame(NSRect(x: x - margin, y: visible.minY, width: Metrics.width + 2 * margin, height: top - visible.minY),
                       display: false)

        if model.permission.status != .authorized { model.permission.refresh() }
        let bluetoothOutputs = model.devices.outputDevices.filter(\.isBluetooth).map { BluetoothAudio.normalize($0.uid) }
        model.bluetooth.refresh(coreAudioIDs: Set(bluetoothOutputs))
        model.bluetooth.proximity.start()

        state.reset()
        model.isMenuOpen = true
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(nil)
        button.highlight(true)

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) ?? false } ? nil : event
        } as Any)
    }

    func close() {
        guard panel.isVisible else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        state.reset()
        model.isMenuOpen = false
        model.bluetooth.proximity.stop()
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
    }

    /// Arrow keys move the highlight, Return or Space clicks, Right and Left open
    /// and close, Escape closes, as in a menu.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.window === panel, !(panel.firstResponder is NSTextView) else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            switch event.charactersIgnoringModifiers {
            case ",": state.openSettings(); return true
            case "q": NSApp.terminate(nil); return true
            default: return false
            }
        }
        switch event.keyCode {
        case 125: state.move(1)
        case 126: state.move(-1)
        case 124: state.expand(true)
        case 123: state.expand(false)
        case 36, 76, 49: state.activate()
        case 53: close()
        default: return false
        }
        return true
    }

    // MARK: Debug hooks (only reachable with the DebugControl default set)

    /// Opens the panel, expands the row named in `row` ("app:<key>" or "np:<key>",
    /// or "app" for the first app) and shows its equalizer when `equalizer` is set.
    func debugExpand(row: String, equalizer: Bool) {
        if !panel.isVisible { show() }
        var row = row
        if row == "app", let key = model.applicationKeys.first { row = "app:\(key)" }
        let key = String(row.drop { $0 != ":" }.dropFirst())
        Motion.animate {
            state.openSections.formUnion([.nowPlaying, .applications])
            state.expandedRow = row
        }
        guard equalizer else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { self.state.eqTarget = key }
        }
    }

    /// Replays named keys ("down down return") against the open panel.
    func debugKeys(_ names: String) {
        if !panel.isVisible { show() }
        for name in names.split(separator: " ") {
            switch name {
            case "down": state.move(1)
            case "up": state.move(-1)
            case "right": state.expand(true)
            case "left": state.expand(false)
            case "return": state.activate()
            default: break
            }
        }
    }
}
