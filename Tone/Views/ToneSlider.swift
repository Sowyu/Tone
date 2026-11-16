import SwiftUI

/// Native slider with speaker symbols at both ends, as in the video.
/// On macOS 26 the system draws the pill knob that turns into a glass lens while dragging.
struct SpeakerSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var tint: Color = .accentColor
    var label: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: $value, in: range) { Text(label) }
                .labelsHidden()
                .tint(tint)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// Knobless native slider with a tick at its neutral value (EQ Preamp and Width).
struct ParameterSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var neutral: Double
    var fillFromNeutral = false
    var label: String

    var body: some View {
        if #available(macOS 26, *) {
            Slider(value: $value, in: range, neutralValue: fillFromNeutral ? neutral : nil) {
                Text(label)
            } ticks: {
                SliderTick(neutral)
            }
            .labelsHidden()
            .sliderThumbVisibility(.hidden)
            .tint(.primary)
        } else {
            Slider(value: $value, in: range) { Text(label) }
                .labelsHidden()
        }
    }
}
