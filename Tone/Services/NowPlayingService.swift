import AppKit
import Observation

struct NowPlayingSession: Identifiable, Equatable {
    /// Source app bundle ID.
    var id: String
    var title: String
    var artist: String
    var album: String
    var artwork: NSImage?
    var isPlaying: Bool
    /// Only the system's current now playing session accepts commands.
    var isCurrent: Bool

    var subtitle: String { [artist, album].filter { !$0.isEmpty }.joined(separator: " — ") }

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.title == b.title && a.artist == b.artist && a.album == b.album
            && a.isPlaying == b.isPlaying && a.isCurrent == b.isCurrent && a.artwork === b.artwork
    }
}

/// Now Playing info.
///
/// macOS 15.4+ only lets Apple-entitled processes read MediaRemote, and there is
/// no public API to read other apps' sessions. Tone bundles the open-source
/// mediaremote-adapter (Vendor/mediaremote-adapter): Apple-signed /usr/bin/perl is
/// allowed to read MediaRemote, and the bundled script loads the adapter framework
/// into it. All of that is isolated in this file. If it stops working, the section
/// is left out and the rest of Tone is unaffected.
@MainActor @Observable
final class NowPlayingService {
    enum Availability: Equatable { case starting, available, missingTool, failed(String) }

    private(set) var sessions: [NowPlayingSession] = []
    private(set) var availability: Availability = .starting

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var restarts = 0
    /// After play/pause, the state Tone already shows. the adapter can report the
    /// old state once more before the new one, which made the button flicker.
    @ObservationIgnored private var expected: (id: String, playing: Bool, until: Date)?

    /// The bundled script and framework, run as `perl script framework function args…`.
    private static let adapter: [String]? = {
        guard let script = Bundle.main.path(forResource: "mediaremote-adapter", ofType: "pl"),
              let framework = Bundle.main.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework").path,
              FileManager.default.fileExists(atPath: framework) else { return nil }
        return [script, framework]
    }()

    private static func adapterProcess(_ arguments: [String]) -> Process? {
        guard let adapter else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = adapter + arguments
        return process
    }

    func start() {
        guard process == nil else { return }
        guard let process = Self.adapterProcess(["stream", "--no-diff", "--debounce=50"]) else {
            availability = .missingTool
            return
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // JSON parsing and artwork decoding stay on the pipe's background queue;
        // the main thread only receives small parsed updates.
        let decoder = NowPlayingDecoder()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let updates = decoder.feed(handle.availableData)
            guard !updates.isEmpty else { return }
            MainLoop.perform { updates.forEach { self?.apply($0) } }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleExit() } }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            availability = .failed(error.localizedDescription)
        }
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }

    private func handleExit() {
        process = nil
        restarts += 1
        guard restarts < 5 else {
            availability = .failed("the Now Playing reader keeps exiting")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { self?.start() }
        }
    }

    private func apply(_ update: NowPlayingUpdate) {
        availability = .available
        restarts = 0
        guard let bundle = update.bundle else {
            // Empty payload: nothing is playing. The last player still takes play
            // commands, so it stays current and its buttons stay enabled.
            sessions = sessions.map { var s = $0; s.isPlaying = held(s.id, false); return s }
            pruneQuitApps()
            return
        }
        let session = NowPlayingSession(id: bundle, title: update.title, artist: update.artist, album: update.album,
                                        artwork: update.artwork, isPlaying: held(bundle, update.playing), isCurrent: true)

        var next = sessions.map { var s = $0; s.isCurrent = false; if s.id != bundle { s.isPlaying = false }; return s }
        if let i = next.firstIndex(where: { $0.id == bundle }) {
            next[i] = session
        } else {
            next.append(session)
        }
        sessions = next
        pruneQuitApps()
    }

    /// The reported state, unless a recent play/pause from Tone hasn't shown up yet.
    private func held(_ id: String, _ reported: Bool) -> Bool {
        guard let expected, expected.id == id else { return reported }
        if reported == expected.playing || Date() > expected.until {
            self.expected = nil
            return reported
        }
        return expected.playing
    }

    /// Older sessions stay listed (paused) until their app quits.
    func pruneQuitApps() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let kept = sessions.filter { $0.isCurrent || running.contains($0.id) }
        if kept != sessions { sessions = kept }
    }

    // MARK: Commands

    /// MediaRemote command IDs.
    private enum Command: Int { case play = 0, pause = 1, nextTrack = 4 }

    func togglePlayPause(_ session: NowPlayingSession) { send(session.isPlaying ? .pause : .play, optimistic: session.id) }
    func next(_ session: NowPlayingSession) { send(.nextTrack, optimistic: nil) }
    /// Pauses whatever the system is playing.
    func pauseCurrent() { send(.pause, optimistic: sessions.first { $0.isCurrent && $0.isPlaying }?.id) }

    private func send(_ command: Command, optimistic id: String?) {
        guard let process = Self.adapterProcess(["send", String(command.rawValue)]) else { return }
        if let id, let i = sessions.firstIndex(where: { $0.id == id }) {
            sessions[i].isPlaying.toggle()
            expected = (id, sessions[i].isPlaying, Date().addingTimeInterval(1.5))
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

struct NowPlayingUpdate: @unchecked Sendable {
    var bundle: String?
    var title = "", artist = "", album = ""
    var artwork: NSImage?
    var playing = false
}

/// Splits the adapter's stream into lines and decodes them. Used only from
/// the pipe's readability queue, which delivers serially.
final class NowPlayingDecoder: @unchecked Sendable {
    private var buffer = Data()
    private var artworkKey = ""
    private var artwork: NSImage?

    func feed(_ data: Data) -> [NowPlayingUpdate] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)
        var updates: [NowPlayingUpdate] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if let update = decode(line) { updates.append(update) }
        }
        return updates
    }

    /// `playing` is the documented flag; some players only update `playbackRate`.
    static func isPlaying(_ payload: [String: Any]) -> Bool {
        if let rate = payload["playbackRate"] as? Double, rate == 0 { return false }
        return payload["playing"] as? Bool ?? false
    }

    private func decode(_ line: Data) -> NowPlayingUpdate? {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        let payload = json["payload"] as? [String: Any] ?? [:]
        guard let bundle = (payload["parentApplicationBundleIdentifier"] as? String) ?? (payload["bundleIdentifier"] as? String),
              let title = payload["title"] as? String else { return NowPlayingUpdate() }
        let base64 = payload["artworkData"] as? String
        let key = "\(bundle)|\(title)|\(base64?.count ?? 0)"
        if key != artworkKey {
            artworkKey = key
            artwork = base64.flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
        }
        return NowPlayingUpdate(bundle: bundle, title: title,
                                artist: payload["artist"] as? String ?? "",
                                album: payload["album"] as? String ?? "",
                                artwork: artwork, playing: Self.isPlaying(payload))
    }
}
