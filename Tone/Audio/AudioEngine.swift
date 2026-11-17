import CoreAudio
import Foundation
import os

/// What the engine should do with one running app.
struct TapRequest {
    let app: AudioApp
    let gain: Float
    let eq: EQSettings?
    var isNeutral: Bool { abs(gain - 1) < 0.0005 && eq == nil }
}

/// Owns every AppTap. Main thread only.
@MainActor
final class AudioEngine {
    static let aggregateUIDPrefix = "com.gooober.tone.aggregate."
    static let log = Logger(subsystem: "com.gooober.tone", category: "audio")

    private var taps: [String: AppTap] = [:]
    private var neutralSince: [String: Date] = [:]
    private(set) var outputUID: String?
    private(set) var lastError: String?

    /// Set when taps run but deliver only silence while the app is playing, which
    /// is what happens when audio capture permission was denied.
    var onSuspectedPermissionDenial: (() -> Void)?
    /// Called when a timed decision is due: a neutral tap's release or a new tap's health check.
    var onNeedsSync: (() -> Void)?

    private func syncLater(_ delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.onNeedsSync?() }
        }
    }

    /// Moves every tap to a new output device. New taps start before old ones
    /// stop so the original audio never leaks through unmuted.
    func setOutputDevice(uid: String?) {
        guard uid != outputUID else { return }
        outputUID = uid
        let old = taps
        taps = [:]
        guard let uid else {
            old.values.forEach { $0.invalidate() }
            return
        }
        for (key, tap) in old {
            do {
                taps[key] = try AppTap(key: key, processes: tap.processes, outputUID: uid,
                                       gain: tap.lastGain, eq: tap.lastEQ)
            } catch {
                record(error, key)
            }
            tap.invalidate()
        }
    }

    /// Brings the taps in line with the requests. Apps not in `requests` lose their tap.
    /// True while Tone taps this app. A tapped app's own output reads as idle to
    /// Core Audio, because its audio now plays through Tone's tap.
    func isTapped(_ key: String) -> Bool { taps[key] != nil }

    func sync(_ requests: [TapRequest], allowTapping: Bool) {
        let wanted = Dictionary(requests.map { ($0.app.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (key, tap) in taps where wanted[key] == nil {
            tap.invalidate()
            taps[key] = nil
            neutralSince[key] = nil
        }
        guard let outputUID else { return }

        let now = Date()
        for request in requests {
            let key = request.app.id
            if let tap = taps[key] {
                if request.isNeutral {
                    // Keep a neutral tap for a few seconds so dragging through 100% doesn't rebuild it.
                    let since = neutralSince[key] ?? now
                    if neutralSince[key] == nil { syncLater(4.1) }
                    neutralSince[key] = since
                    if now.timeIntervalSince(since) > 4 {
                        tap.invalidate()
                        taps[key] = nil
                        neutralSince[key] = nil
                        continue
                    }
                } else {
                    neutralSince[key] = nil
                }
                do {
                    try tap.updateProcesses(request.app.processObjects)
                    tap.apply(gain: request.gain, eq: request.eq)
                } catch {
                    // Couldn't edit the tap in place: rebuild it.
                    record(error, key)
                    if let fresh = try? AppTap(key: key, processes: request.app.processObjects, outputUID: outputUID,
                                               gain: request.gain, eq: request.eq) {
                        taps[key] = fresh
                    } else {
                        taps[key] = nil
                    }
                    tap.invalidate()
                }
            } else if !request.isNeutral, allowTapping {
                do {
                    taps[key] = try AppTap(key: key, processes: request.app.processObjects, outputUID: outputUID,
                                           gain: request.gain, eq: request.eq)
                    Self.log.info("Tapped \(key, privacy: .public)")
                    syncLater(3.5)
                } catch {
                    record(error, key)
                }
            }
        }
    }

    /// Checks for the "permission denied" pattern: playing app, running tap, all-zero input.
    func checkForSilentTaps(playing: Set<String>, olderThan age: TimeInterval) {
        for (key, tap) in taps where playing.contains(key) && Date().timeIntervalSince(tap.createdAt) > age {
            if !tap.kernel.sawSignal.load(ordering: .relaxed), tap.kernel.callbackCount.load(ordering: .relaxed) > 50 {
                Self.log.error("Tap for \(key, privacy: .public) delivers silence; capture permission is probably denied")
                stopAll()
                onSuspectedPermissionDenial?()
                return
            }
        }
    }

    func stopAll() {
        taps.values.forEach { $0.invalidate() }
        taps = [:]
        neutralSince = [:]
    }

    func diagnostics() -> [(key: String, callbacks: UInt64, peakIn: Float, peakOut: Float, overloads: Int, rate: Double)] {
        taps.map { key, tap in
            let peaks = tap.kernel.takePeaks()
            return (key, tap.kernel.callbackCount.load(ordering: .relaxed), peaks.input, peaks.output, tap.overloads, tap.kernel.sampleRate)
        }
    }

    private func record(_ error: Error, _ key: String) {
        lastError = "\(key): \(error)"
        Self.log.error("Tap error for \(key, privacy: .public): \(String(describing: error), privacy: .public)")
    }
}
