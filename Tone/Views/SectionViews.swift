import CoreAudio
import SwiftUI

struct AccordionSection: View {
    @Environment(AppModel.self) private var model
    let section: PopoverSection
    @FocusState private var focused: Bool

    private var isOpen: Bool { model.openSections.contains(section) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack {
                    Text(section.rawValue)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, Metrics.inset)
                .frame(height: Metrics.sectionRowHeight)
                .hoverHighlight(focused: focused)
            }
            .buttonStyle(.plain)
            .focusRow($focused, action: toggle)
            .accessibilityLabel(section.rawValue)
            .accessibilityValue(isOpen ? "expanded" : "collapsed")

            if isOpen {
                content.transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }

    private func toggle() {
        Motion.animate {
            if isOpen { model.openSections.remove(section) } else { model.openSections.insert(section) }
        }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .output:
            DeviceList(devices: model.devices.outputDevices, selected: model.devices.defaultOutputID) {
                model.devices.setDefaultOutput($0)
            }
        case .input:
            DeviceList(devices: model.devices.inputDevices, selected: model.devices.defaultInputID) {
                model.devices.setDefaultInput($0)
            }
        case .nowPlaying:
            NowPlayingList()
        case .applications:
            ApplicationList()
        }
    }
}

struct DeviceList: View {
    let devices: [AudioDevice]
    let selected: AudioObjectID
    let choose: (AudioDevice) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if devices.isEmpty { EmptyHint(text: "No devices") }
            ForEach(devices) { device in
                DeviceRow(device: device, isSelected: device.id == selected) { choose(device) }
            }
        }
        .padding(.bottom, 4)
    }
}

/// Same shape as the device rows in the system Sound menu.
private struct DeviceRow: View {
    let device: AudioDevice
    let isSelected: Bool
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: device.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
                Text(device.name).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.inset)
            .frame(height: 30)
            .hoverHighlight(focused: focused)
        }
        .buttonStyle(.plain)
        .focusRow($focused, action: action)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct EmptyHint: View {
    let text: String
    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Metrics.inset)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
