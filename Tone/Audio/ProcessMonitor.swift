import AppKit
import CoreAudio
import Observation

/// An app that owns one or more Core Audio process objects (helpers are grouped
/// under the app that is responsible for them).
struct AudioApp: Identifiable, Equatable {
    /// Bundle ID, or `exe:<name>` for command line tools without one.
    let id: String
    let name: String
    let pid: pid_t
    var processObjects: [AudioObjectID]
    var isPlaying: Bool

    static func == (a: AudioApp, b: AudioApp) -> Bool {
        a.id == b.id && a.pid == b.pid && a.processObjects == b.processObjects && a.isPlaying == b.isPlaying
    }
}

/// Watches kAudioHardwarePropertyProcessObjectList and each process's
/// kAudioProcessPropertyIsRunningOutput, grouping processes by app.
@MainActor @Observable
final class ProcessMonitor {
    private(set) var apps: [String: AudioApp] = [:]

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var listListener: PropertyListener?
    @ObservationIgnored private var processListeners: [AudioObjectID: PropertyListener] = [:]
    @ObservationIgnored private var identityCache: [pid_t: (key: String, name: String, pid: pid_t)] = [:]
    @ObservationIgnored private var pending = false

    init() {
        listListener = PropertyListener(CA.system, CA.address(kAudioHardwarePropertyProcessObjectList)) { [weak self] in
            self?.scheduleRefresh()
        }
        refresh()
        // Helpers launched by NSWorkspace apps sometimes resolve late; a slow poll catches it.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func scheduleRefresh() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                self?.pending = false
                self?.refresh()
            }
        }
    }

    func refresh() {
        let objects = CA.getArray(CA.system, CA.address(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var grouped: [String: AudioApp] = [:]
        var alivePIDs = Set<pid_t>()

        for object in objects {
            guard let pid = CA.get(object, CA.address(kAudioProcessPropertyPID), as: pid_t.self), pid != ownPID else { continue }
            alivePIDs.insert(pid)
            if processListeners[object] == nil {
                processListeners[object] = PropertyListener(object, CA.address(kAudioProcessPropertyIsRunningOutput)) { [weak self] in
                    self?.scheduleRefresh()
                }
            }
            let running = (CA.get(object, CA.address(kAudioProcessPropertyIsRunningOutput), as: UInt32.self) ?? 0) != 0
            guard let identity = identity(for: pid, object: object) else { continue }
            if var app = grouped[identity.key] {
                app.processObjects.append(object)
                app.isPlaying = app.isPlaying || running
                grouped[identity.key] = app
            } else {
                grouped[identity.key] = AudioApp(id: identity.key, name: identity.name, pid: identity.pid,
                                                 processObjects: [object], isPlaying: running)
            }
        }

        let live = Set(objects)
        for (object, listener) in processListeners where !live.contains(object) {
            listener.cancel()
            processListeners[object] = nil
        }
        identityCache = identityCache.filter { alivePIDs.contains($0.key) }

        if grouped != apps {
            apps = grouped
            onChange?()
        }
    }

    // MARK: Identity

    private static let ignoredBundleIDs: Set<String> = [
        "com.apple.audio.coreaudiod", "com.apple.systemsoundserverd", "com.apple.CoreSpeech",
        "com.apple.audio.SandboxHelper", "com.apple.powerchime", "com.apple.accessibility.heard",
    ]

    private static let ignoredExecutables: Set<String> = ["systemsoundserverd", "coreaudiod", "SpeechSynthesisServerXPC"]

    private func identity(for pid: pid_t, object: AudioObjectID) -> (key: String, name: String, pid: pid_t)? {
        if let cached = identityCache[pid] { return cached }
        let caBundle = CA.getString(object, CA.address(kAudioProcessPropertyBundleID)).flatMap { $0.isEmpty ? nil : $0 }
        if let caBundle, Self.ignoredBundleIDs.contains(caBundle) { return nil }

        var result: (key: String, name: String, pid: pid_t)?
        // 1. The responsible app (e.g. "Google Chrome" for a renderer helper).
        let responsible = Responsibility.responsiblePID(for: pid)
        for candidate in [responsible, pid].compactMap({ $0 }) {
            if let app = NSRunningApplication(processIdentifier: candidate), app.activationPolicy == .regular,
               let bundle = app.bundleIdentifier {
                result = (bundle, app.localizedName ?? bundle, candidate)
                break
            }
        }
        // 2. Bundle ID prefix match against running apps (com.foo.App.helper -> com.foo.App).
        if result == nil, let caBundle {
            let parent = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { app in app.bundleIdentifier.map { (app, $0) } }
                .filter { caBundle.hasPrefix($0.1 + ".") || caBundle == $0.1 }
                .max { $0.1.count < $1.1.count }
            if let (app, bundle) = parent { result = (bundle, app.localizedName ?? bundle, app.processIdentifier) }
        }
        // 3. Plain processes: CLI tools like afplay or say.
        if result == nil {
            let running = NSRunningApplication(processIdentifier: pid)
            if let caBundle, caBundle.hasPrefix("com.apple.") {
                // Background Apple daemons that play UI sounds; not worth a row.
                return nil
            }
            // No name means a process we can't inspect (root daemons): not worth a row.
            guard let exe = running?.executableURL?.lastPathComponent ?? Responsibility.processName(pid),
                  !Self.ignoredExecutables.contains(exe) else { return nil }
            result = (caBundle ?? "exe:\(exe)", running?.localizedName ?? exe, pid)
        }
        identityCache[pid] = result
        return result
    }
}

/// Private libsystem SPI used by Activity Monitor to map helpers to their app.
/// Looked up dynamically; if it is missing we fall back to bundle ID prefixes.
enum Responsibility {
    private typealias Fn = @convention(c) (pid_t) -> pid_t
    private static let fn: Fn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: Fn.self)
    }()

    static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let fn else { return nil }
        let r = fn(pid)
        return r > 0 && r != pid ? r : nil
    }

    static func processName(_ pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, 256)
        return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : nil
    }
}
