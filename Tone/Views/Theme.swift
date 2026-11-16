import Foundation

enum Metrics {
    /// Width of the menu and of the SwiftUI rows inside it.
    static let menuWidth: CGFloat = 300
    /// Left and right margin of native menu items on macOS 27.
    static let inset: CGFloat = 16
}

enum SpeakerSymbol {
    static func name(volume: Double, muted: Bool) -> String {
        if muted || volume <= 0.001 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

extension Double {
    /// "+11.3" or "−1.1", with a real minus sign.
    var signedDB: String {
        if abs(self) < 0.05 { return "0.0" }
        return (self > 0 ? "+" : "\u{2212}") + String(format: "%.1f", abs(self))
    }

    var percent: String { "\(Int((self * 100).rounded()))%" }
}
