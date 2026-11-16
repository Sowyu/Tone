import AppKit
import SwiftUI

/// A menu item that runs a closure.
@MainActor
final class ActionItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, state: NSControl.StateValue = .off, enabled: Bool = true,
         handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        self.state = state
        target = self
        isEnabled = enabled
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

private extension NSMenuItem {
    /// Greyed-out text, such as "Not Playing".
    static func placeholder(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    static func submenu(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }
}

/// The status item and its menu.
///
/// Everything is a native menu item except the rows that hold a control: the
/// volume sliders and the Now Playing transport buttons.
@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let openSettings: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var eqWindows: [String: NSWindow] = [:]
    private var deviceItems: [NSMenuItem] = []
    private var appItems: [NSMenuItem] = []
    private var structure: [String] = []
    /// Bumped on every rebuild and close so stale observations stop re-arming.
    private var generation = 0

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

    // MARK: Menu lifecycle

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        model.isMenuOpen = true
        if model.permission.status != .authorized { model.permission.refresh() }
        let bluetoothOutputs = model.devices.outputDevices.filter(\.isBluetooth).map { BluetoothAudio.normalize($0.uid) }
        model.bluetooth.refresh(coreAudioIDs: Set(bluetoothOutputs))
        rebuild()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        model.isMenuOpen = false
        generation += 1
    }

    /// App submenus are filled as they open, so their checkmarks are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if let key = menu.identifier?.rawValue { fillAppMenu(menu, key: key) }
    }

    /// Keeps the open menu live. A change in the set of rows rebuilds the menu;
    /// anything else (volume, battery, selection) only refreshes item titles.
    private func observe() {
        let generation = generation
        withObservationTracking {
            _ = structureSignature()
            deviceItems.forEach(styleOutput)
            appItems.forEach(styleApp)
        } onChange: { [weak self] in
            MainLoop.perform {
                guard let self, self.generation == generation else { return }
                if self.structureSignature() == self.structure { self.observe() } else { self.rebuild() }
            }
        }
    }

    /// Everything that decides which items exist.
    private func structureSignature() -> [String] {
        let devices = model.devices
        let bluetooth = model.bluetooth
        return devices.outputDevices.map(\.uid) + ["|"]
            + devices.inputDevices.map { "\($0.uid)\($0.id == devices.defaultInputID)" } + ["|"]
            + bluetooth.disconnected.map(\.id) + ["|"]
            + [devices.defaultOutput.flatMap(bluetooth.details)?.modes.map(\.title).joined() ?? "",
               "\(devices.defaultOutput.flatMap(bluetooth.details)?.listeningMode?.rawValue ?? 0)",
               "\(showsNowPlaying)", "\(model.permission.status)", "|"]
            + model.nowPlaying.sessions.map(\.id) + ["|"]
            + model.applicationKeys
    }

    // MARK: Building

    /// Without media-control the section is left out; Settings explains how to get it.
    private var showsNowPlaying: Bool {
        switch model.nowPlaying.availability {
        case .starting, .available: true
        case .missingTool, .failed: false
        }
    }

    private func rebuild() {
        generation += 1
        structure = structureSignature()
        deviceItems = []
        appItems = []
        var items: [NSMenuItem] = []

        let devices = model.devices
        items.append(.hosting(VolumeRow(title: "Sound", accessibilityLabel: "Output Volume",
                                        value: Binding(get: { Double(devices.masterVolume) },
                                                       set: { devices.setMasterVolume(Float($0)) }),
                                        isEnabled: { devices.canSetVolume })))

        items.append(.separator())
        items.append(.sectionHeader(title: "Output"))
        items += outputItems()

        items.append(.separator())
        items.append(.submenu("Input", inputMenu()))

        if showsNowPlaying {
            items.append(.separator())
            items.append(.sectionHeader(title: "Now Playing"))
            let sessions = model.nowPlaying.sessions
            if sessions.isEmpty { items.append(.placeholder("Not Playing")) }
            for session in sessions {
                items.append(.hosting(NowPlayingRow(id: session.id).environment(model)))
            }
        }

        items.append(.separator())
        items.append(.sectionHeader(title: "Applications"))
        items += applicationItems()

        items.append(.separator())
        items.append(ActionItem("Settings…") { [weak self] in self?.openSettings() })
        items.append(NSMenuItem(title: "Quit Tone", action: #selector(NSApplication.terminate), keyEquivalent: ""))

        // New items go in before the old ones come out: emptying an open menu and
        // refilling it leaves it taller than its contents.
        for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
        while menu.numberOfItems > items.count { menu.removeItem(at: items.count) }
        observe()
    }

    private func outputItems() -> [NSMenuItem] {
        let devices = model.devices
        var items: [NSMenuItem] = []
        for device in devices.outputDevices {
            let item = ActionItem("") { devices.setDefaultOutput(device) }
            item.representedObject = device.uid
            // An item with a submenu can't be clicked, so only the selected device gets one.
            if device.id == devices.defaultOutputID, let details = model.bluetooth.details(for: device), !details.modes.isEmpty {
                item.submenu = listeningMenu(for: device, details: details)
            }
            deviceItems.append(item)
            items.append(item)
        }
        // Paired but not connected, as in the system Sound menu: click to connect.
        for paired in model.bluetooth.disconnected {
            let item = ActionItem("") { [weak self] in
                guard let self else { return }
                self.model.bluetooth.connect(paired, devices: self.model.devices)
            }
            item.representedObject = paired
            deviceItems.append(item)
            items.append(item)
        }
        return items
    }

    private func styleOutput(_ item: NSMenuItem) {
        if let paired = item.representedObject as? BluetoothAudio.Paired {
            let connecting = model.bluetooth.connecting.contains(paired.id)
            item.attributedTitle = MenuTitle.device(name: paired.name, symbol: paired.symbol, selected: false,
                                                    trailing: connecting ? "Connecting…" : nil)
        } else if let device = model.devices.outputDevices.first(where: { $0.uid == item.representedObject as? String }) {
            let battery = model.bluetooth.details(for: device)?.battery
            item.attributedTitle = MenuTitle.device(name: device.name, symbol: device.symbol,
                                                    selected: device.id == model.devices.defaultOutputID,
                                                    trailing: (battery?.buds ?? battery?.main).map { "\($0)%" })
        }
    }

    private func listeningMenu(for device: AudioDevice, details: BluetoothDetails) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(.sectionHeader(title: "Listening Mode"))
        for mode in details.modes {
            submenu.addItem(ActionItem(mode.title, state: details.listeningMode == mode ? .on : .off) { [weak self] in
                self?.model.bluetooth.setListeningMode(mode, for: device)
            })
        }
        return submenu
    }

    private func inputMenu() -> NSMenu {
        let devices = model.devices
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for device in devices.inputDevices {
            submenu.addItem(ActionItem(device.name, state: device.id == devices.defaultInputID ? .on : .off) {
                devices.setDefaultInput(device)
            })
        }
        if submenu.items.isEmpty { submenu.addItem(.placeholder("No Input Devices")) }
        return submenu
    }

    private func applicationItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if model.permission.status == .denied {
            items.append(ActionItem("Allow System Audio Recording…") { [weak self] in self?.model.permission.openSystemSettings() })
        }
        let keys = model.applicationKeys
        if keys.isEmpty { items.append(.placeholder("No Apps Playing Audio")) }
        for key in keys {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            submenu.delegate = self
            submenu.identifier = NSUserInterfaceItemIdentifier(key)
            let item = NSMenuItem.submenu(model.displayName(key), submenu)
            item.representedObject = key
            appItems.append(item)
            items.append(item)
        }
        return items
    }

    private func styleApp(_ item: NSMenuItem) {
        guard let key = item.representedObject as? String else { return }
        item.attributedTitle = MenuTitle.app(name: model.displayName(key), icon: model.icon(key),
                                             trailing: model.settings(key).volume.percent,
                                             dimmed: model.processes.apps[key] == nil)
    }

    // MARK: Per-app submenu

    private func fillAppMenu(_ submenu: NSMenu, key: String) {
        let model = self.model
        let settings = model.settings(key)
        submenu.removeAllItems()
        submenu.addItem(.hosting(AppVolumeRow(key: key).environment(model)))
        submenu.addItem(ActionItem("Reset Volume", enabled: abs(settings.volume - 1) > 0.001) { model.resetVolume(key) })

        submenu.addItem(.separator())
        submenu.addItem(ActionItem("Equalizer", state: settings.eqEnabled ? .on : .off) {
            model.setEQEnabled(key, !settings.eqEnabled)
        })
        let preset = NSMenuItem.submenu("Preset", presetMenu(for: key, current: settings.presetName))
        preset.badge = NSMenuItemBadge(string: settings.presetName)
        submenu.addItem(preset)
        submenu.addItem(ActionItem("Show Equalizer…") { [weak self] in self?.showEqualizer(key) })

        submenu.addItem(.separator())
        let keys = model.applicationKeys
        let index = keys.firstIndex(of: key) ?? 0
        submenu.addItem(ActionItem("Move Up", enabled: index > 0) { model.moveApp(key, by: -1) })
        submenu.addItem(ActionItem("Move Down", enabled: index < keys.count - 1) { model.moveApp(key, by: 1) })

        submenu.addItem(.separator())
        submenu.addItem(ActionItem("Keep in Menu", state: model.store.state.pinned.contains(key) ? .on : .off) {
            model.togglePinned(key)
        })
        submenu.addItem(ActionItem("Hide from Menu") { model.hide(key) })
    }

    private func presetMenu(for key: String, current: String) -> NSMenu {
        let model = self.model
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        func add(_ presets: [EQPreset]) {
            for preset in presets {
                submenu.addItem(ActionItem(preset.name, state: preset.name == current ? .on : .off) { model.applyPreset(key, preset) })
            }
        }
        add(PresetStore.builtIn)
        if !model.presets.custom.isEmpty {
            submenu.addItem(.separator())
            add(model.presets.custom)
        }
        submenu.addItem(.separator())
        submenu.addItem(ActionItem("Save as Preset…") { [weak self] in self?.saveAsPreset(key) })
        return submenu
    }

    // MARK: Windows

    func showEqualizer(_ key: String) {
        let window = eqWindows[key] ?? {
            let panel = NSPanel(contentViewController: NSHostingController(rootView: EQPanel(key: key).environment(model)))
            panel.styleMask = [.titled, .closable, .utilityWindow]
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.title = "\(model.displayName(key)) Equalizer"
            panel.center()
            eqWindows[key] = panel
            return panel
        }()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func saveAsPreset(_ key: String) {
        let alert = NSAlert()
        alert.messageText = "Save as Preset"
        alert.informativeText = "Enter a name for this equalizer setting."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 228, height: 22))
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

    // MARK: Debug hooks (only reachable with the DebugControl default set)

    /// Pops the menu up under the top-right corner, replays the keys named in the
    /// DebugKeys default ("up up right") and closes after 12 s, because
    /// notifications can't reach the app while a menu is tracking.
    func debugOpen() {
        guard let frame = NSScreen.main?.visibleFrame else { return }
        let keys = (UserDefaults.standard.string(forKey: "DebugKeys") ?? "").split(separator: " ")
        for (index, key) in keys.enumerated() {
            schedule(after: 0.8 + Double(index) * 0.5) { Self.postKey(String(key)) }
        }
        schedule(after: 12) { [weak self] in self?.menu.cancelTracking() }
        menu.popUp(positioning: nil, at: NSPoint(x: frame.maxX - Metrics.menuWidth - 40, y: frame.maxY - 6), in: nil)
    }

    private func schedule(after delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated(body) }
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func postKey(_ name: String) {
        let (code, character): (UInt16, String) = switch name {
        case "down": (125, "\u{F701}")
        case "up": (126, "\u{F700}")
        case "right": (124, "\u{F703}")
        case "left": (123, "\u{F702}")
        default: (36, "\r")
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                            characters: character, charactersIgnoringModifiers: character,
                                            isARepeat: false, keyCode: code) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }
}
