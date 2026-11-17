import Foundation

struct EQSettings: Codable, Equatable, Sendable {
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
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
    /// 0 up to the maximum app volume (at most 5), where 1 is 100%.
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
        case .speaker: "Speaker"
        case .slider: "Sliders"
        case .waveform: "Waveform"
        }
    }

    /// The speaker style swaps this for a glyph that follows the output volume.
    var symbol: String {
        switch self {
        case .speaker: "speaker.wave.2.fill"
        case .slider: "slider.horizontal.3"
        case .waveform: "waveform"
        }
    }
}

/// Magnitude response of the same biquads the DSP runs, for drawing the EQ curve.
enum EQResponse {
    static let sampleRate = 48_000.0

    static func decibels(_ eq: EQSettings, frequencies: [Double]) -> [Double] {
        let c = DSPKernel.coefficients(for: eq, sampleRate: sampleRate)
        return frequencies.map { f in
            let w = 2 * Double.pi * f / sampleRate
            let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
            var total = 0.0
            for band in 0..<DSPKernel.bandCount {
                let b0 = c[band * 5], b1 = c[band * 5 + 1], b2 = c[band * 5 + 2]
                let a1 = c[band * 5 + 3], a2 = c[band * 5 + 4]
                let nr = b0 + b1 * c1 + b2 * c2, ni = b1 * s1 + b2 * s2
                let dr = 1 + a1 * c1 + a2 * c2, di = a1 * s1 + a2 * s2
                total += 10 * log10(max((nr * nr + ni * ni) / max(dr * dr + di * di, 1e-12), 1e-12))
            }
            return total
        }
    }
}

#if DEBUG
extension EQResponse {
    /// Runs at launch in Debug builds: the drawn curve must match the DSP's filters.
    static func selfCheck() {
        var eq = EQSettings.flat
        assert(decibels(eq, frequencies: [1000]).first.map { abs($0) < 0.001 } == true, "flat EQ must be 0 dB")
        eq.bands[5] = 6
        let peak = decibels(eq, frequencies: [1000])[0]
        assert(abs(peak - 6) < 0.05, "a +6 dB band must read +6 dB at its centre, got \(peak)")
    }
}
#endif
