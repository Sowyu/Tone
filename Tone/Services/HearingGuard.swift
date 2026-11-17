import AppKit

/// Warns when headphone audio stays loud. Once a second it takes the level of
/// everything playing, applies the output volume and estimates dB SPL. When the
/// last 30 seconds average above the limit, it shows a warning that can pause playback.
///
/// The estimate is rough: Tone can't know how loud a given pair of headphones
/// plays, so it assumes a full-scale signal at full volume reaches `referenceDB`.
@MainActor
final class HearingGuard {
    // ponytail: one reference level for all headphones; per-device calibration if people report it firing early or late
    static let referenceDB = 100.0
    static let limits: [Double] = [80, 85, 90, 95, 100]
    private static let window = 30

    private unowned let model: AppModel
    private var levels: [Double] = []
    private var snoozedUntil = Date.distantPast
    private var timer: Timer?

    init(model: AppModel) {
        self.model = model
        // Default run loop mode, so it doesn't tick while its own alert is up.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Estimated dB SPL for a mean-square level at a volume scalar. The volume
    /// slider is roughly square-law in amplitude, so power goes with its 4th power.
    static func decibels(meanSquare: Double, volume: Double) -> Double {
        10 * log10(max(meanSquare * pow(volume, 4), 1e-12)) + referenceDB
    }

    private func tick() {
        let state = model.store.state
        let active = state.hearingWarning && model.permission.status == .authorized
            && model.devices.defaultOutput?.isHeadphones == true
        model.engine.metering = active
        guard active, let meanSquare = model.engine.takeMeanSquare() else {
            levels.removeAll()
            return
        }
        let volume = model.devices.isMuted ? 0 : Double(model.devices.masterVolume)
        levels.append(meanSquare * pow(volume, 4))
        if levels.count > Self.window { levels.removeFirst(levels.count - Self.window) }
        guard levels.count == Self.window, Date() > snoozedUntil else { return }
        let average = levels.reduce(0, +) / Double(levels.count)
        let db = Self.decibels(meanSquare: average, volume: 1)
        if db >= state.hearingLimit { warn(db) }
    }

    private func warn(_ db: Double) {
        levels.removeAll()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Headphone audio is loud"
        alert.informativeText = "Your headphones have been playing at about \(Int(db.rounded())) dB for the last 30 seconds. Listening this loud for a long time can damage your hearing."
        alert.addButton(withTitle: "Pause Music")
        alert.addButton(withTitle: "Continue")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            model.nowPlaying.pauseCurrent()
            snoozedUntil = Date().addingTimeInterval(60)
        } else {
            // Asked once, so stay quiet for the rest of this listening session.
            snoozedUntil = Date().addingTimeInterval(60 * 60)
        }
    }
}
