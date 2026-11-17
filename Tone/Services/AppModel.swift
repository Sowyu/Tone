import AppKit
import Observation
import ServiceManagement

/// Ties the audio, device, now playing and storage services to the UI.
@MainActor @Observable
final class AppModel {
    let devices = DeviceManager()
    let processes = ProcessMonitor()
    let nowPlaying = NowPlayingService()
    let presets = PresetStore()
    let store = SettingsStore()
    let permission = CapturePermission()
    let bluetooth = BluetoothAudio()
    @ObservationIgnored let engine = AudioEngine()

    /// True while the panel is open; it only renders, and the marquee only runs, then.
    var isMenuOpen = false

    /// Apps that produced audio at least once since they launched.
    @ObservationIgnored private var everPlayed = Set<String>()
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        devices.onDefaultOutputChanged = { [weak self] _ in self?.outputDeviceChanged() }
        processes.onChange = { [weak self] in self?.syncEngine() }
        engine.onSuspectedPermissionDenial = { [weak self] in self?.permission.markDenied() }
        engine.setOutputDevice(uid: devices.defaultOutput?.uid)
        nowPlaying.start()
        syncEngine()
        // No polling: the engine asks for a re-sync when a neutral tap is due
        // for release or a new tap needs its health check.
        engine.onNeedsSync = { [weak self] in self?.healthCheck() }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.nowPlaying.pruneQuitApps() }
        })
        Diagnostics.shared.attach(self)
        #if DEBUG
        EQResponse.selfCheck()
        AirPodsLink.selfCheck()
        #endif
    }

    private func healthCheck() {
        syncEngine()
        guard permission.status != .authorized else { return }
        permission.refresh()
        let playing = Set(processes.apps.values.filter(\.isPlaying).map(\.id))
        engine.checkForSilentTaps(playing: playing, olderThan: 3)
    }

    private func outputDeviceChanged() {
        devices.refreshDevices()
        engine.setOutputDevice(uid: devices.defaultOutput?.uid)
        syncEngine()
    }

    // MARK: Engine

    var canTap: Bool { permission.status != .denied }

    func syncEngine() {
        let apps = processes.apps
        for app in apps.values where app.isPlaying { everPlayed.insert(app.id) }
        everPlayed.formIntersection(apps.keys)
        for app in apps.values where store.state.names[app.id] != app.name { store.state.names[app.id] = app.name }

        let requests = apps.values.map { app -> TapRequest in
            let s = store.settings(for: app.id)
            return TapRequest(app: app, gain: s.gain, eq: s.eqEnabled ? s.eq : nil)
        }
        engine.sync(requests, allowTapping: canTap)
    }

    // MARK: Applications

    /// Apps in the Applications section, in menu order: everything that has
    /// played since it launched, plus pinned apps, minus hidden ones.
    var applicationKeys: [String] {
        let state = store.state
        var keys = Set(processes.apps.values.filter { everPlayed.contains($0.id) || $0.isPlaying }.map(\.id))
        keys.formUnion(state.pinned)
        keys.subtract(state.hidden)
        return SettingsStore.ordered(keys.sorted { displayName($0).localizedCompare(displayName($1)) == .orderedAscending },
                                     by: state.appOrder)
    }

    func displayName(_ key: String) -> String {
        if let app = processes.apps[key] { return app.name }
        if let name = store.state.names[key] { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return key.hasPrefix("exe:") ? String(key.dropFirst(4)) : key
    }

    func icon(_ key: String) -> NSImage {
        if let cached = icons[key] { return cached }
        var image: NSImage?
        if let pid = processes.apps[key]?.pid { image = NSRunningApplication(processIdentifier: pid)?.icon }
        if image == nil, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        let result = image ?? NSWorkspace.shared.icon(for: .unixExecutable)
        icons[key] = result
        return result
    }

    // MARK: Per-app settings

    var overdriveLimit: Double { store.state.overdriveLimit }

    func settings(_ key: String) -> AppAudioSettings { store.settings(for: key) }

    func setVolume(_ key: String, _ volume: Double) {
        store.update(key) { $0.volume = min(max(volume, 0), overdriveLimit) }
        requestPermissionIfNeeded()
        syncEngine()
    }

    func setEQEnabled(_ key: String, _ on: Bool) {
        store.update(key) { $0.eqEnabled = on }
        requestPermissionIfNeeded()
        syncEngine()
    }

    func setEQ(_ key: String, _ change: (inout EQSettings) -> Void) {
        store.update(key) {
            change(&$0.eq)
            $0.presetName = PresetStore.customName
            $0.eqEnabled = true
        }
        syncEngine()
    }

    func applyPreset(_ key: String, _ preset: EQPreset) {
        store.update(key) {
            // Width belongs to the user, presets only change the curve and preamp.
            let q = $0.eq.q
            $0.eq = preset.eq
            $0.eq.q = q
            $0.presetName = preset.name
            $0.eqEnabled = true
        }
        requestPermissionIfNeeded()
        syncEngine()
    }

    func resetVolume(_ key: String) {
        store.update(key) { $0.volume = 1 }
        syncEngine()
    }

    func togglePinned(_ key: String) {
        if store.state.pinned.contains(key) {
            store.state.pinned.removeAll { $0 == key }
        } else {
            store.state.pinned.append(key)
            store.state.names[key] = displayName(key)
        }
    }

    func hide(_ key: String) {
        if !store.state.hidden.contains(key) { store.state.hidden.append(key) }
        store.state.pinned.removeAll { $0 == key }
    }

    func unhide(_ key: String) { store.state.hidden.removeAll { $0 == key } }

    func moveApp(_ key: String, by delta: Int) {
        let keys = applicationKeys
        guard let index = keys.firstIndex(of: key), keys.indices.contains(index + delta) else { return }
        store.state.appOrder = SettingsStore.move(key, to: keys[index + delta], visible: keys, order: store.state.appOrder)
    }

    private func requestPermissionIfNeeded() {
        guard permission.status == .unknown else { return }
        permission.request { [weak self] _ in self?.syncEngine() }
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                AudioEngine.log.error("Launch at login: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func shutdown() {
        engine.stopAll()
        nowPlaying.stop()
        store.flush()
    }
}
