import AppKit
import SwiftUI

/// NSMenuItem that runs a closure.
@MainActor
final class ActionItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, key: String = "", state: NSControl.StateValue = .off, enabled: Bool = true,
         handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: enabled ? #selector(run) : nil, keyEquivalent: key)
        self.state = state
        target = self
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// The status item and its real NSMenu.
///
/// Native items (section headers, separators, checkmark items, submenus) are
/// used wherever AppKit has them. Rows that need a slider, an icon circle or
/// artwork are SwiftUI views in custom-view items; AppKit still tracks their
/// hover and keyboard highlight, and the views draw the native highlight.
@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let openSettings: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var structure = ""
    private var eqWindows: [String: NSWindow] = [:]
    private var appSubmenus: [ObjectIdentifier: String] = [:]

    init(model: AppModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.setAccessibilityLabel("Tone")
        updateIcon()
    }

    /// Closes the menu from code (debug hook).
    func close() { menu.cancelTracking() }

    /// Opens the menu from code (debug hook and `--open`). With an auto-hidden
    /// menu bar the status button can't be clicked, so pop up under the top-right corner.
    func open() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        // Debug openings close themselves: notifications can't reach the app while a menu tracks.
        let timer = Timer(timeInterval: 12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        RunLoop.main.add(timer, forMode: .common)
        menu.popUp(positioning: nil, at: NSPoint(x: frame.maxX - Metrics.menuWidth - 40, y: frame.maxY - 6), in: nil)
    }

    // MARK: Icon

    private func updateIcon() {
        withObservationTracking {
            let name: String = switch model.store.state.iconStyle {
            case .speaker: SpeakerSymbol.name(volume: Double(model.devices.masterVolume), muted: model.devices.isMuted)
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

    // MARK: Menu lifecycle

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        model.isMenuOpen = true
        if model.permission.status != .authorized { model.permission.refresh() }
        model.bluetooth.refresh(coreAudioIDs: bluetoothOutputIDs)
        rebuild()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        model.isMenuOpen = false
    }

    /// Submenus are rebuilt each time they open so checkmarks are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if let key = appSubmenus[ObjectIdentifier(menu)] { fillAppMenu(menu, key: key) }
    }

    private var bluetoothOutputIDs: Set<String> {
        Set(model.devices.outputDevices.filter(\.isBluetooth).map { BluetoothAudio.normalize($0.uid) })
    }

    /// Rebuilds the item list when the menu's shape changes (devices, apps, sessions,
    /// expansion). Values inside rows update on their own through observation.
    private func observeStructure() {
        withObservationTracking {
            _ = structureSignature()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.model.isMenuOpen, self.structureSignature() != self.structure else {
                        self?.observeStructure()
                        return
                    }
                    self.rebuild()
                }
            }
        }
    }

    private func structureSignature() -> String {
        let d = model.devices
        let bt = model.bluetooth
        return [
            d.outputDevices.map(\.uid).joined(separator: ","),
            d.inputDevices.map(\.uid).joined(separator: ","),
            "\(d.defaultInputID)",
            bt.disconnected.map(\.id).joined(separator: ","),
            bt.details.map { "\($0.key):\($0.value.modes.count)" }.sorted().joined(separator: ","),
            model.expandedDevice ?? "",
            model.nowPlayingRows.map(\.id).joined(separator: ","),
            "\(model.nowPlaying.availability)",
            model.applicationRows.map(\.id).joined(separator: ","),
            "\(model.permission.status)",
        ].joined(separator: "|")
    }

    // MARK: Building

    private func rebuild() {
        structure = structureSignature()
        appSubmenus = [:]
        menu.removeAllItems()

        menu.addItem(viewItem { _ in HeaderRow() })
        menu.addItem(viewItem { _ in MasterSliderRow() })

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Output"))
        addOutputs()

        menu.addItem(.separator())
        let input = NSMenuItem(title: "Input", action: nil, keyEquivalent: "")
        input.submenu = inputMenu()
        menu.addItem(input)

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Now Playing"))
        addNowPlaying()

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Applications"))
        addApplications()

        menu.addItem(.separator())
        let settings = ActionItem("Sound Settings…", key: ",") { [weak self] in self?.openSettings() }
        settings.keyEquivalentModifierMask = .command
        menu.addItem(settings)

        observeStructure()
    }

    private func viewItem<Content: View>(action: (@MainActor () -> Void)? = nil,
                                         @ViewBuilder _ content: @escaping (RowState) -> Content) -> NSMenuItem {
        let item: NSMenuItem = action.map { ActionItem("", handler: $0) } ?? NSMenuItem()
        let model = self.model
        item.view = MenuHostView { state in content(state).environment(model) }
        return item
    }

    private func addOutputs() {
        let devices = model.devices
        for device in devices.outputDevices {
            let details = model.bluetooth.details(for: device)
            let expandable = !(details?.modes.isEmpty ?? true)
            let expanded = expandable && model.expandedDevice == device.uid
            var row: NSMenuItem?
            row = viewItem(action: { devices.setDefaultOutput(device) }) { [weak self] state in
                DeviceRowView(state: state, name: device.name, symbol: device.symbol,
                              isSelected: self?.model.devices.defaultOutputID == device.id,
                              battery: self?.model.bluetooth.details(for: device)?.battery,
                              expandable: expandable, expanded: expanded,
                              onToggleExpand: { self?.model.expandedDevice = expanded ? nil : device.uid },
                              activate: { (row?.view as? MenuHostView)?.activate() })
            }
            menu.addItem(row!)
            if expanded, let details {
                let title = NSMenuItem.sectionHeader(title: "Listening Mode")
                title.indentationLevel = 1
                menu.addItem(title)
                for mode in details.modes {
                    var modeRow: NSMenuItem?
                    modeRow = viewItem(action: { [weak self] in self?.model.bluetooth.setListeningMode(mode, for: device) }) { [weak self] state in
                        ModeRowView(state: state, mode: mode,
                                    isSelected: self?.model.bluetooth.details(for: device)?.listeningMode == mode,
                                    activate: { (modeRow?.view as? MenuHostView)?.activate() })
                    }
                    menu.addItem(modeRow!)
                }
            }
        }
        // Paired but disconnected, like the system Sound menu: click to connect.
        for paired in model.bluetooth.disconnected {
            var row: NSMenuItem?
            row = viewItem(action: { [weak self] in
                guard let self else { return }
                self.model.bluetooth.connect(paired, devices: self.model.devices)
            }) { [weak self] state in
                DeviceRowView(state: state, name: paired.name, symbol: paired.symbol, isSelected: false,
                              isConnecting: self?.model.bluetooth.connecting.contains(paired.id) ?? false,
                              activate: { (row?.view as? MenuHostView)?.activate() })
            }
            menu.addItem(row!)
        }
    }

    private func inputMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for device in model.devices.inputDevices {
            submenu.addItem(ActionItem(device.name, state: device.id == model.devices.defaultInputID ? .on : .off) { [weak self] in
                self?.model.devices.setDefaultInput(device)
            })
        }
        if submenu.items.isEmpty { submenu.addItem(ActionItem("No Input Devices", enabled: false) {}) }
        return submenu
    }

    private func addNowPlaying() {
        switch model.nowPlaying.availability {
        case .missingTool:
            menu.addItem(ActionItem("Install media-control to show what's playing", enabled: false) {})
            return
        case .failed:
            menu.addItem(ActionItem("Now Playing isn't available", enabled: false) {})
            return
        case .starting, .available:
            break
        }
        let rows = model.nowPlayingRows
        if rows.isEmpty { menu.addItem(ActionItem("Not Playing", enabled: false) {}) }
        for session in rows {
            let item = viewItem { state in SessionRowView(state: state, id: session.id) }
            item.submenu = appMenu(for: session.id, movable: false)
            menu.addItem(item)
        }
    }

    private func addApplications() {
        if model.permission.status == .denied {
            menu.addItem(ActionItem("Allow System Audio Recording…") { [weak self] in self?.model.permission.openSystemSettings() })
        }
        let rows = model.applicationRows
        if rows.isEmpty { menu.addItem(ActionItem("No Apps Playing Audio", enabled: false) {}) }
        for row in rows {
            let item = viewItem { state in AppRowView(state: state, initial: row) }
            item.submenu = appMenu(for: row.id, movable: true)
            menu.addItem(item)
        }
    }

    // MARK: Per-app submenu

    private func appMenu(for key: String, movable: Bool) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.delegate = self
        appSubmenus[ObjectIdentifier(submenu)] = key
        submenu.identifier = NSUserInterfaceItemIdentifier(movable ? "app" : "session")
        fillAppMenu(submenu, key: key)
        return submenu
    }

    private func fillAppMenu(_ submenu: NSMenu, key: String) {
        let movable = submenu.identifier?.rawValue == "app"
        let s = model.settings(key)
        submenu.removeAllItems()
        submenu.addItem(viewItem { _ in AppVolumeRow(key: key) })
        submenu.addItem(.separator())

        submenu.addItem(ActionItem("Equalizer", state: s.eqEnabled ? .on : .off) { [weak self] in
            guard let self else { return }
            self.model.setEQEnabled(key, !self.model.settings(key).eqEnabled)
        })
        submenu.addItem(ActionItem("Show Equalizer…") { [weak self] in self?.showEqualizer(key) })

        let preset = NSMenuItem(title: "Preset", action: nil, keyEquivalent: "")
        preset.badge = NSMenuItemBadge(string: s.presetName)
        let presets = NSMenu()
        presets.autoenablesItems = false
        for p in PresetStore.builtIn {
            presets.addItem(ActionItem(p.name, state: p.name == s.presetName ? .on : .off) { [weak self] in self?.model.applyPreset(key, p) })
        }
        if !model.presets.custom.isEmpty {
            presets.addItem(.separator())
            for p in model.presets.custom {
                presets.addItem(ActionItem(p.name, state: p.name == s.presetName ? .on : .off) { [weak self] in self?.model.applyPreset(key, p) })
            }
        }
        presets.addItem(.separator())
        presets.addItem(ActionItem("Save as Preset…") { [weak self] in self?.saveAsPreset(key) })
        preset.submenu = presets
        submenu.addItem(preset)

        submenu.addItem(.separator())
        submenu.addItem(ActionItem("Always Show", state: model.store.state.pinned.contains(key) ? .on : .off) { [weak self] in
            self?.model.togglePinned(key)
        })
        submenu.addItem(ActionItem("Reset Volume", enabled: abs(s.volume - 1) > 0.001) { [weak self] in self?.model.resetVolume(key) })
        submenu.addItem(ActionItem("Hide") { [weak self] in self?.model.hide(key) })
        if movable {
            submenu.addItem(.separator())
            submenu.addItem(ActionItem("Move Up") { [weak self] in self?.model.moveApp(key, by: -1) })
            submenu.addItem(ActionItem("Move Down") { [weak self] in self?.model.moveApp(key, by: 1) })
        }
    }

    // MARK: Windows

    func showEqualizer(_ key: String) {
        let window = eqWindows[key] ?? {
            let controller = NSHostingController(rootView: EQPanel(key: key).environment(model))
            let window = NSPanel(contentViewController: controller)
            window.styleMask = [.titled, .closable, .utilityWindow, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isFloatingPanel = true
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.title = "\(model.displayName(key)) Equalizer"
            window.center()
            eqWindows[key] = window
            return window
        }()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func saveAsPreset(_ key: String) {
        let alert = NSAlert()
        alert.messageText = "Save as Preset"
        alert.informativeText = "Enter a name for this equalizer setting."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        field.placeholderString = "Preset Name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.presets.save(name: name, eq: model.settings(key).eq) {
            model.store.update(key) { $0.presetName = name }
        } else {
            NSSound.beep()
        }
    }
}
