import Foundation

/// Opt-in test hooks, off by default:
///   defaults write com.gooober.tone DebugControl -bool YES
/// Then Tone writes per-tap stats once a second to ~/Library/Logs/Tone/diagnostics.log
/// and accepts the distributed notification "com.gooober.tone.debug.set" with
/// userInfo {key, volume?, eqEnabled?, preset?, output?} so scripts can drive it.
/// The hooks that open the panel and windows are in AppDelegate.
@MainActor
final class Diagnostics {
    static let shared = Diagnostics()
    private weak var model: AppModel?
    private var timer: Timer?
    private var handle: FileHandle?

    var enabled: Bool { UserDefaults.standard.bool(forKey: "DebugControl") }

    func attach(_ model: AppModel) {
        guard enabled else { return }
        self.model = model
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Tone")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("diagnostics.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)

        DistributedNotificationCenter.default().addObserver(forName: .init("com.gooober.tone.debug.set"), object: nil, queue: .main) { note in
            let info = note.userInfo ?? [:]
            let key = info["key"] as? String
            let volume = (info["volume"] as? NSNumber)?.doubleValue
            let eq = (info["eqEnabled"] as? NSNumber)?.boolValue
            let preset = info["preset"] as? String
            let output = info["output"] as? String
            let engineOutput = info["engineOutput"] as? String
            let listening = (info["listeningMode"] as? NSNumber)?.uint8Value
            MainActor.assumeIsolated {
                if let engineOutput { self.model?.engine.setOutputDevice(uid: engineOutput) }
                if let listening, let mode = ListeningMode(rawValue: listening), let model = self.model,
                   let device = model.devices.outputDevices.first(where: \.isBluetooth) {
                    model.bluetooth.setListeningMode(mode, for: device)
                }
                self.handle(key: key, volume: volume, eq: eq, preset: preset, output: output)
            }
        }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.dump() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func handle(key: String?, volume: Double?, eq: Bool?, preset: String?, output: String?) {
        guard let model else { return }
        if let output, let device = model.devices.outputDevices.first(where: { $0.name == output || $0.uid == output }) {
            model.devices.setDefaultOutput(device)
        }
        guard let key else { return }
        if let volume { model.setVolume(key, volume) }
        if let eq { model.setEQEnabled(key, eq) }
        if let preset, let p = model.presets.preset(named: preset) { model.applyPreset(key, p) }
        write("cmd key=\(key) volume=\(volume.map { "\($0)" } ?? "-") eq=\(eq.map { "\($0)" } ?? "-") preset=\(preset ?? "-")")
    }

    private func dump() {
        guard let model else { return }
        let apps = model.processes.apps.values.map { "\($0.id)[\($0.isPlaying ? "playing" : "idle") procs=\($0.processObjects.count)]" }
        var lines = ["t=\(Date().timeIntervalSince1970) output=\(model.devices.defaultOutput?.name ?? "-") permission=\(model.permission.status) apps=\(apps.sorted())"]
        for d in model.engine.diagnostics().sorted(by: { $0.key < $1.key }) {
            let ratio = d.peakIn > 0.0001 ? d.peakOut / d.peakIn : 0
            lines.append(String(format: "  tap %@ rate=%.0f callbacks=%llu peakIn=%.4f peakOut=%.4f ratio=%.3f overloads=%d",
                                d.key, d.rate, d.callbacks, d.peakIn, d.peakOut, ratio, d.overloads))
        }
        lines.append("  nowPlaying " + model.nowPlaying.sessions.map { "\($0.id) playing=\($0.isPlaying) current=\($0.isCurrent)" }.joined(separator: "; "))
        if let error = model.engine.lastError { lines.append("  lastError \(error)") }
        lines.forEach(write)
    }

    private func write(_ line: String) {
        handle?.write(Data((line + "\n").utf8))
    }
}
