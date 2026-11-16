import AppKit
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
                .frame(height: Metrics.rowHeight)
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
            DeviceList(devices: model.devices.outputDevices, selected: model.devices.defaultOutputID, showsPaired: true) {
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
    @Environment(AppModel.self) private var model
    let devices: [AudioDevice]
    let selected: AudioObjectID
    var showsPaired = false
    let choose: (AudioDevice) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if devices.isEmpty { EmptyHint(text: "No devices") }
            ForEach(devices) { device in
                DeviceRow(name: device.name, symbol: device.symbol, isSelected: device.id == selected,
                          battery: model.battery.level(for: device)) { choose(device) }
            }
            if showsPaired {
                // Paired but not connected, like the system menu: click to connect.
                ForEach(model.bluetooth.disconnected) { paired in
                    DeviceRow(name: paired.name, symbol: paired.symbol, isSelected: false, battery: nil,
                              isConnecting: model.bluetooth.connecting.contains(paired.id)) {
                        model.bluetooth.connect(paired, devices: model.devices)
                    }
                }
            }
        }
        .padding(.bottom, 4)
        .onAppear { if showsPaired { model.bluetooth.refresh() } }
        .onChange(of: devices) { if showsPaired { model.bluetooth.refresh() } }
    }
}

/// Matches the device rows in the system Sound menu: the device's own glyph in a
/// 26 pt circle (accent when selected), earbud battery under the name, and
/// headphone battery on the right.
private struct DeviceRow: View {
    let name: String
    let symbol: String
    let isSelected: Bool
    let battery: BatteryLevel?
    var isConnecting = false
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    Circle().fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.1)))
                    if isConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(Color.primary.opacity(0.75)))
                    }
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).lineLimit(1)
                    if let buds = battery?.buds {
                        HStack(spacing: 3) {
                            Image(systemName: Self.symbol("airpod.left", fallback: "earbuds"))
                                .font(.system(size: 9))
                            Text("\(buds)%")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if battery?.buds == nil, let main = battery?.main {
                    Text("\(main)%").foregroundStyle(.secondary)
                    Image(systemName: Self.batterySymbol(main))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Metrics.inset)
            .frame(minHeight: Metrics.rowHeight)
            .hoverHighlight(focused: focused)
        }
        .buttonStyle(.plain)
        .focusRow($focused, action: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    static func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    static func symbol(_ name: String, fallback: String) -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : fallback
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
