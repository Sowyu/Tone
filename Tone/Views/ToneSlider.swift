import SwiftUI

/// Thin track filling blue, white round thumb with a soft shadow.
/// Arrow keys adjust it when focused.
struct ToneSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double = 0.01
    /// Draws a faint tick at this value (100% on overdrive sliders).
    var mark: Double?
    /// Fill from this value instead of the lower bound (0 dB on bipolar sliders).
    var origin: Double?
    var accessibilityLabel: String = "Volume"
    var accessibilityValue: String = ""
    var onEditingChanged: (Bool) -> Void = { _ in }

    @FocusState private var focused: Bool
    @State private var dragging = false
    private let thumb: CGFloat = 16
    private let track: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width - thumb
            let x = CGFloat(fraction(value)) * width
            let originX = CGFloat(fraction(origin ?? range.lowerBound)) * width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18)).frame(height: track)
                    .padding(.horizontal, thumb / 2)
                Capsule().fill(Color.blue)
                    .frame(width: abs(x - originX) + (origin == nil ? thumb / 2 : 0), height: track)
                    .offset(x: origin == nil ? thumb / 2 : min(x, originX) + thumb / 2)
                if let mark {
                    Capsule().fill(.white.opacity(0.45)).frame(width: 2, height: 8)
                        .offset(x: CGFloat(fraction(mark)) * width + thumb / 2 - 1)
                }
                Circle().fill(.white)
                    .frame(width: thumb, height: thumb)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .overlay(Circle().strokeBorder(Color.blue.opacity(focused ? 0.9 : 0), lineWidth: 2))
                    .scaleEffect(dragging ? 1.12 : 1)
                    .animation(Motion.spring, value: dragging)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging { dragging = true; onEditingChanged(true) }
                        set(Double((g.location.x - thumb / 2) / max(width, 1)))
                    }
                    .onEnded { _ in dragging = false; onEditingChanged(false) }
            )
        }
        .frame(height: 20)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { nudge(-1); return .handled }
        .onKeyPress(.rightArrow) { nudge(1); return .handled }
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            nudge(direction == .increment ? 1 : -1)
        }
    }

    private func fraction(_ v: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? min(max((v - range.lowerBound) / span, 0), 1) : 0
    }

    private func set(_ fraction: Double) {
        let raw = range.lowerBound + min(max(fraction, 0), 1) * (range.upperBound - range.lowerBound)
        var snapped = (raw / step).rounded() * step
        // Light magnet at the mark so 100% is easy to hit.
        if let mark, abs(snapped - mark) < (range.upperBound - range.lowerBound) * 0.015 { snapped = mark }
        value = min(max(snapped, range.lowerBound), range.upperBound)
    }

    private func nudge(_ direction: Double) {
        value = min(max(value + direction * step * 5, range.lowerBound), range.upperBound)
    }
}
