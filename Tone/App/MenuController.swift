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
        isEnabled = enabled
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
    private var deviceItems: [NSMenuItem] = []
    private var appItems: [NSMenuItem] = []

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

    private static func postKey(_ name: String) {
        let (code, char): (UInt16, String) = switch name {
        case "down": (125, "\u{F701}")
        case "up": (126, "\u{F700}")
        case "right": (124, "\u{F703}")
        case "left": (123, "\u{F702}")
        default: (36, "\r")
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: 0, context: nil, characters: char, charactersIgnoringModifiers: char,
                                            isARepeat: false, keyCode: code) {
                NSApp.postEvent(event, atStart: false)
            }
        }
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
        // Debug: replay keys (defaults key DebugKeys, e.g. "down down right") to test highlight and submenus.
        let keys = (UserDefaults.standard.string(forKey: "DebugKeys") ?? "").split(separator: " ")
        for (i, key) in keys.enumerated() {
            let t = Timer(timeInterval: 0.8 + Double(i) * 0.5, repeats: false) { _ in
                MainActor.assumeIsolated { Self.postKey(String(key)) }
            }
            RunLoop.main.add(t, forMode: .common)
        }
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
            MainLoop.perform {
                guard let self, self.model.isMenuOpen, self.structureSignature() != self.structure else {
                    self?.observeStructure()
                    return
                }
                self.rebuild()
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
            bt.details.map { "\($0.key):\($0.value.listeningMode?.rawValue ?? 0)" }.sorted().joined(separator: ","),
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
        deviceItems = []
        appItems = []
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
        observeContent()
    }

    private func viewItem<Content: View>(action: (@MainActor () -> Void)? = nil,
                                         @ViewBuilder _ content: @escaping (RowState) -> Content) -> NSMenuItem {
        let item: NSMenuItem = action.map { ActionItem("", handler: $0) } ?? NSMenuItem()
        let model = self.model
        item.view = MenuHostView { state in content(state).environment(model) }
        return item
    }

    /// Output devices as native items: AppKit handles hover, click, keyboard and
    /// submenus. The round icon and battery live in the attributed title.
    private func addOutputs() {
        let devices = model.devices
        for device in devices.outputDevices {
            let item = ActionItem("") { devices.setDefaultOutput(device) }
            item.representedObject = device.uid
            styleOutput(item)
            if let details = model.bluetooth.details(for: device), !details.modes.isEmpty {
                item.submenu = listeningMenu(for: device, details: details)
            }
            deviceItems.append(item)
            menu.addItem(item)
        }
        // Paired but disconnected, like the system Sound menu: click to connect.
        for paired in model.bluetooth.disconnected {
            let item = ActionItem("") { [weak self] in
                guard let self else { return }
                self.model.bluetooth.connect(paired, devices: self.model.devices)
            }
            item.representedObject = "paired:" + paired.id
            styleOutput(item)
            deviceItems.append(item)
            menu.addItem(item)
        }
    }

    /// Recomputes a device item's title from live state (selection, battery, connecting).
    private func styleOutput(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        if id.hasPrefix("paired:") {
            let pid = String(id.dropFirst(7))
            guard let paired = model.bluetooth.disconnected.first(where: { $0.id == pid }) else { return }
            let connecting = model.bluetooth.connecting.contains(pid)
            item.attributedTitle = MenuTitle.device(name: paired.name, symbol: paired.symbol, selected: false,
                                                    trailing: connecting ? "Connecting…" : nil)
            return
        }
        guard let device = model.devices.outputDevices.first(where: { $0.uid == id }) else { return }
        let battery = model.bluetooth.details(for: device)?.battery
        let trailing = battery.flatMap { $0.buds ?? $0.main }.map { "\($0)%" }
        item.attributedTitle = MenuTitle.device(name: device.name, symbol: device.symbol,
                                                selected: device.id == model.devices.defaultOutputID, trailing: trailing)
    }

    private func listeningMenu(for device: AudioDevice, details: BluetoothDetails) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(.sectionHeader(title: "Listening Mode"))
        for mode in details.modes {
            let item = ActionItem(mode.title, state: details.listeningMode == mode ? .on : .off) { [weak self] in
                self?.model.bluetooth.setListeningMode(mode, for: device)
            }
            item.attributedTitle = MenuTitle.symbol(MenuTitle.modeIcon(mode), title: mode.title)
            submenu.addItem(item)
        }
        return submenu
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
            menu.addItem(viewItem { state in SessionRowView(state: state, id: session.id) })
        }
    }

    private func addApplications() {
        if model.permission.status == .denied {
            menu.addItem(ActionItem("Allow System Audio Recording…") { [weak self] in self?.model.permission.openSystemSettings() })
        }
        let rows = model.applicationRows
        if rows.isEmpty { menu.addItem(ActionItem("No Apps Playing Audio", enabled: false) {}) }
        for row in rows {
            let item = NSMenuItem(title: row.name, action: nil, keyEquivalent: "")
            item.representedObject = row.id
            item.submenu = appMenu(for: row.id, movable: true)
            styleApp(item)
            appItems.append(item)
            menu.addItem(item)
        }
    }

    private func styleApp(_ item: NSMenuItem) {
        guard let key = item.representedObject as? String else { return }
        let settings = model.settings(key)
        item.attributedTitle = MenuTitle.app(name: model.displayName(key), icon: model.icon(key),
                                             percent: settings.volume.percent, overdrive: settings.volume > 1.0001,
                                             dimmed: model.processes.apps[key] == nil)
    }

    /// Updates titles in place when values change, without rebuilding the menu.
    private func observeContent() {
        withObservationTracking {
            _ = contentSignature()
        } onChange: { [weak self] in
            MainLoop.perform {
                guard let self else { return }
                self.deviceItems.forEach(self.styleOutput)
                self.appItems.forEach(self.styleApp)
                self.observeContent()
            }
        }
    }

    private func contentSignature() -> String {
        let volumes = model.applicationRows.map { "\($0.id)=\(model.settings($0.id).volume)" }
        let battery = model.bluetooth.details.map { "\($0.key)=\($0.value.battery?.buds ?? $0.value.battery?.main ?? -1)" }
        return ([String(model.devices.defaultOutputID)] + volumes + battery.sorted()
                + model.bluetooth.connecting.sorted()).joined(separator: ",")
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
            let ids = model.applicationRows.map(\.id)
            let index = ids.firstIndex(of: key) ?? 0
            submenu.addItem(ActionItem("Move Up", enabled: index > 0) { [weak self] in self?.model.moveApp(key, by: -1) })
            submenu.addItem(ActionItem("Move Down", enabled: index < ids.count - 1) { [weak self] in self?.model.moveApp(key, by: 1) })
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
