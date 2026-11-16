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
                SectionHeader(title: section.rawValue, isOpen: isOpen, focused: focused && KeyboardMode.shared.active)
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

/// Section titles are plain labels like in the system menus: no hover slab.
/// Hovering only brightens the title and chevron.
private struct SectionHeader: View {
    let title: String
    let isOpen: Bool
    let focused: Bool
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(title).fontWeight(.semibold)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .medium))
                .rotationEffect(.degrees(isOpen ? 90 : 0))
        }
        .foregroundStyle(hovering || focused ? .primary : .secondary)
        .padding(.horizontal, Metrics.inset)
        .frame(height: Metrics.rowHeight)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
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
                let details = showsPaired ? model.bluetooth.details(for: device) : nil
                let expandable = !(details?.modes.isEmpty ?? true)
                let expanded = expandable && model.expandedDevice == device.uid
                DeviceRow(name: device.name, symbol: device.symbol, isSelected: device.id == selected,
                          battery: details?.battery, expandable: expandable, expanded: expanded,
                          onExpand: {
                              Motion.animate { model.expandedDevice = expanded ? nil : device.uid }
                          }) { choose(device) }
                if expanded, let details {
                    ListeningModes(details: details) { model.bluetooth.setListeningMode($0, for: device) }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
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
/// 26 pt circle (accent when selected), earbud battery under the name, headphone
/// battery on the right, and a chevron for devices with listening modes.
private struct DeviceRow: View {
    let name: String
    let symbol: String
    let isSelected: Bool
    let battery: BatteryLevel?
    var isConnecting = false
    var expandable = false
    var expanded = false
    var onExpand: () -> Void = {}
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
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
                        Image(systemName: "airpod.left").font(.system(size: 9))
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
            if expandable {
                Button(action: onExpand) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 24, height: Metrics.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Hide listening modes" : "Show listening modes")
            }
        }
        .padding(.horizontal, Metrics.inset)
        .frame(minHeight: Metrics.rowHeight)
        .hoverHighlight(focused: focused)
        .onTapGesture(perform: action)
        .focusRow($focused, action: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
}

/// The darker band under an expanded AirPods row, laid out like the system menu:
/// checkmark column, mode glyph, title.
private struct ListeningModes: View {
    let details: BluetoothDetails
    let choose: (ListeningMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Listening Mode")
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Metrics.inset)
                .frame(height: 28)
            ForEach(details.modes) { mode in
                ModeRow(mode: mode, isSelected: details.listeningMode == mode) { choose(mode) }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.16))
    }
}

private struct ModeRow: View {
    let mode: ListeningMode
    let isSelected: Bool
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .opacity(isSelected ? 1 : 0)
                .frame(width: 30, alignment: .leading)
            ModeGlyph(mode: mode)
                .frame(width: 30, alignment: .leading)
            Text(mode.title)
            Spacer(minLength: 0)
        }
        .padding(.leading, Metrics.inset + 4)
        .frame(height: 24)
        .hoverHighlight(focused: focused)
        .onTapGesture(perform: action)
        .focusRow($focused, action: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct ModeGlyph: View {
    let mode: ListeningMode

    var body: some View {
        Group {
            switch mode {
            case .off: Image(systemName: "person.fill")
            case .transparency: Image(systemName: "person.and.background.dotted")
            case .noiseCancellation: Image(systemName: "person.bust.circle.fill")
            case .adaptive:
                Image(systemName: "person.fill")
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "sparkle").font(.system(size: 8, weight: .bold)).offset(x: 5, y: -3)
                    }
            }
        }
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
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
