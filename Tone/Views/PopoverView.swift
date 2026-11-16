import SwiftUI

/// Fills the transparent panel window: EQ slot on the left, popover on the right.
struct PopoverRoot: View {
    @Environment(AppModel.self) private var model
    let onSettings: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: PanelController.gap) {
            ZStack(alignment: .topTrailing) {
                if let key = model.eqTarget {
                    EQPanel(key: key)
                        .id(key)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(width: PanelController.eqWidth, alignment: .topTrailing)
            .padding(.vertical, 20)
            .padding(.leading, 20)
            .clipped()
            .padding(.vertical, -20)
            .padding(.leading, -20)

            PopoverView(onSettings: onSettings)
                .frame(width: PanelController.popoverWidth)
        }
        .padding(.horizontal, PanelController.margin)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onExitCommand(perform: onClose)
        .preferredColorScheme(.dark)
        .tint(.blue)
    }
}

struct PopoverView: View {
    @Environment(AppModel.self) private var model
    let onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sound")
                .font(.system(size: 15, weight: .bold))
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)

            MasterVolumeRow()
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            Divider().padding(.horizontal, 14)

            VStack(spacing: 2) {
                ForEach(PopoverSection.allCases) { section in
                    AccordionSection(section: section)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)

            Divider().padding(.horizontal, 14)

            Button(action: onSettings) {
                HStack {
                    Text("Sound Settings…")
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .rowHighlight()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .font(.system(size: 13))
        .panelCard()
    }
}

struct MasterVolumeRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let devices = model.devices
        let volume = Binding(get: { Double(devices.masterVolume) }, set: { devices.setMasterVolume(Float($0)) })
        HStack(spacing: 10) {
            Button {
                devices.setMuted(!devices.isMuted)
            } label: {
                Image(systemName: SpeakerSymbol.name(volume: volume.wrappedValue, muted: devices.isMuted))
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20, alignment: .leading)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(devices.isMuted ? "Unmute" : "Mute")

            ToneSlider(value: volume, accessibilityLabel: "Output volume",
                       accessibilityValue: "\(Int((volume.wrappedValue * 100).rounded())) percent")
                .disabled(!devices.canSetVolume)

            Text("\(Int((volume.wrappedValue * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}
