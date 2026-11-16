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
/// no public API to read other apps' sessions. Tone therefore talks to the
/// open-source `media-control` tool (brew install media-control), which reaches
/// MediaRemote through an Apple-signed host process. All of that is isolated in
/// this file. If the tool is missing or stops working, the section shows a hint
/// and the rest of Tone is unaffected.
@MainActor @Observable
final class NowPlayingService {
    enum Availability: Equatable { case starting, available, missingTool, failed(String) }

    private(set) var sessions: [NowPlayingSession] = []
    private(set) var availability: Availability = .starting

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var restarts = 0
    @ObservationIgnored private var artworkCache: (key: String, image: NSImage?)?

    static let toolPaths = ["/opt/homebrew/bin/media-control", "/usr/local/bin/media-control"]
    var toolPath: String? { Self.toolPaths.first { FileManager.default.isExecutableFile(atPath: $0) } }

    func start() {
        guard process == nil else { return }
        guard let toolPath else {
            availability = .missingTool
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = ["stream", "--no-diff", "--debounce=150"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(data) } }
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
            availability = .failed("media-control keeps exiting")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { self?.start() }
        }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: Data(line))
        }
    }

    private func handle(line: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        availability = .available
        restarts = 0
        let payload = json["payload"] as? [String: Any] ?? [:]
        guard let bundle = (payload["parentApplicationBundleIdentifier"] as? String) ?? (payload["bundleIdentifier"] as? String),
              let title = payload["title"] as? String else {
            // Empty payload: nothing is playing any more.
            sessions = sessions.map { var s = $0; s.isPlaying = false; s.isCurrent = false; return s }
            pruneQuitApps()
            return
        }
        let artworkBase64 = payload["artworkData"] as? String
        let artworkKey = "\(bundle)|\(title)|\(artworkBase64?.count ?? 0)"
        let artwork: NSImage?
        if let cached = artworkCache, cached.key == artworkKey {
            artwork = cached.image
        } else {
            artwork = artworkBase64.flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
            artworkCache = (artworkKey, artwork)
        }
        let session = NowPlayingSession(
            id: bundle, title: title,
            artist: payload["artist"] as? String ?? "",
            album: payload["album"] as? String ?? "",
            artwork: artwork,
            isPlaying: payload["playing"] as? Bool ?? false,
            isCurrent: true)

        var next = sessions.map { var s = $0; s.isCurrent = false; if s.id != bundle { s.isPlaying = false }; return s }
        if let i = next.firstIndex(where: { $0.id == bundle }) {
            next[i] = session
        } else {
            next.append(session)
        }
        sessions = next
        pruneQuitApps()
    }

    /// Older sessions stay listed (paused) until their app quits.
    func pruneQuitApps() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let kept = sessions.filter { $0.isCurrent || running.contains($0.id) }
        if kept != sessions { sessions = kept }
    }

    // MARK: Commands

    func togglePlayPause(_ session: NowPlayingSession) { send(session.isPlaying ? "pause" : "play", optimistic: session.id) }
    func next(_ session: NowPlayingSession) { send("next-track", optimistic: nil) }

    private func send(_ command: String, optimistic id: String?) {
        guard let toolPath else { return }
        if let id, let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].isPlaying.toggle() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = [command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
