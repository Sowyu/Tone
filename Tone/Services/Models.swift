import Foundation

struct EQSettings: Codable, Equatable, Sendable {
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]
    static let range: ClosedRange<Double> = -12...12
    static let qRange: ClosedRange<Double> = 0.3...4

    var bands: [Double] = Array(repeating: 0, count: 10)
    var preamp: Double = 0
    var q: Double = 1.4

    static let flat = EQSettings()
}

struct EQPreset: Codable, Identifiable, Equatable, Sendable {
    var id: String { name }
    var name: String
    var eq: EQSettings
}

/// Everything Tone remembers about one app, keyed by bundle ID.
struct AppAudioSettings: Codable, Equatable, Sendable {
    /// 0...2, where 1 is 100%.
    var volume: Double = 1
    var eqEnabled = false
    var eq = EQSettings.flat
    var presetName = "Flat"

    /// Linear gain for the DSP. Square law below 100% so the slider feels even;
    /// linear above it so 200% is +6 dB.
    var gain: Float {
        let v = max(0, volume)
        return Float(v <= 1 ? v * v : v)
    }
}

enum MenuBarIconStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case speaker, slider, waveform
    var id: String { rawValue }
    var title: String {
        switch self {
        case .speaker: "Speaker (follows volume)"
        case .slider: "Sliders"
        case .waveform: "Waveform"
        }
    }
}

enum PopoverSection: String, CaseIterable, Identifiable, Codable {
    case output = "Output", input = "Input", nowPlaying = "Now Playing", applications = "Applications"
    var id: String { rawValue }
}
