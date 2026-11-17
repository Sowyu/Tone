import AppKit
import SwiftUI

/// Measured from a native NSMenu on macOS 27 (2x screenshots, values in points).
enum Metrics {
    static let width: CGFloat = 300
    /// Text and separator inset from the panel edge.
    static let inset: CGFloat = 16
    /// The hover highlight is inset from the panel edge and rounded.
    static let highlightInset: CGFloat = 5
    static let highlightRadius: CGFloat = 10
    static let cornerRadius: CGFloat = 12
    static let rowHeight: CGFloat = 24
    static let deviceRowHeight: CGFloat = 32
    static let appIcon: CGFloat = 18
    /// Transparent room around the panel for its shadow.
    static let shadowMargin: CGFloat = 40
}

enum Motion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// The one spring every expand and collapse uses. Reduce Motion swaps it for a short fade.
    static var spring: Animation { reduce ? .easeInOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.86) }

    static func animate(_ body: () -> Void) { withAnimation(spring, body) }
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
