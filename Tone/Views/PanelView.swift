import AppKit
import SwiftUI

/// Fills the transparent panel window. The surface hangs from the top and
/// springs to its content's height; nothing renders while the panel is closed.
struct PanelRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let room = geo.size.height - 2 * Metrics.shadowMargin
            VStack(spacing: 0) {
                if model.isMenuOpen {
                    Group {
                        if contentHeight > room {
                            ScrollView { content }
                                .scrollIndicators(.automatic)
                                .frame(height: room)
                        } else {
                            content
                        }
                    }
                    .frame(width: Metrics.width)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
                    .modifier(PanelSurface())
                }
            }
            .padding(.horizontal, Metrics.shadowMargin)
            .padding(.top, Metrics.shadowMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .font(.system(size: NSFont.systemFontSize))
        .onPreferenceChange(MenuRowsKey.self) { rows in
            MainActor.assumeIsolated { panel.rows = rows }
        }
    }

    private var content: some View {
        PanelContent()
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
    }
}

struct PanelContent: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel

    /// Without media-control the section is left out; Settings explains how to get it.
    private var showsNowPlaying: Bool {
        switch model.nowPlaying.availability {
        case .starting, .available: true
        case .missingTool, .failed: false
        }
    }

    var body: some View {
        let devices = model.devices
        VStack(alignment: .leading, spacing: 0) {
            VolumeHeader(title: "Sound", accessibilityLabel: "Output Volume",
                         value: Binding(get: { Double(devices.masterVolume) }, set: { devices.setMasterVolume(Float($0)) }))
                .disabled(!devices.canSetVolume)
                .padding(.horizontal, Metrics.inset)
                .padding(.top, 10)
                .padding(.bottom, 5)

            ForEach(PanelSection.allCases) { section in
                if section != .nowPlaying || showsNowPlaying {
                    MenuSeparator()
                    SectionHeader(section: section)
                    if panel.openSections.contains(section) {
                        sectionContent(section)
                            .padding(.bottom, 2)
                            .transition(.opacity)
                    }
                }
            }

            MenuSeparator()
            PlainRow(id: "settings", title: "Settings…", shortcut: "⌘,") { panel.openSettings() }
            PlainRow(id: "quit", title: "Quit Tone", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .padding(.bottom, 6)
        }
        .clipped()
    }

    @ViewBuilder private func sectionContent(_ section: PanelSection) -> some View {
        VStack(spacing: 0) {
            switch section {
            case .output: OutputList()
            case .input: InputList()
            case .nowPlaying: NowPlayingList()
            case .applications: ApplicationList()
            }
        }
    }
}

/// Text with an optional key equivalent on the right, like a plain menu item.
struct PlainRow: View {
    let id: String
    let title: String
    var shortcut: String?
    let action: @MainActor () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let shortcut {
                Text(shortcut).foregroundStyle(.secondary)
            }
        }
        .menuRow(id, action: action)
    }
}

/// A bold title with the level beside it, above a slider between two speaker glyphs.
struct VolumeHeader: View {
    let title: String
    let accessibilityLabel: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).fontWeight(.semibold)
                Spacer()
                Text(value.percent)
                    .monospacedDigit()
                    .foregroundStyle(value > 1.0001 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .contentTransition(.numericText(value: value))
            }
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                Slider(value: $value, in: range) { Text(accessibilityLabel) }
                    .labelsHidden()
                Image(systemName: "speaker.wave.3.fill")
            }
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: Devices

struct OutputList: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel

    var body: some View {
        let devices = model.devices
        if devices.outputDevices.isEmpty && model.bluetooth.disconnected.isEmpty { PlaceholderRow(text: "No Output Devices") }
        ForEach(devices.outputDevices) { device in
            OutputItem(device: device)
        }
        // Paired but not connected, as in the system Sound menu: click to connect.
        ForEach(model.bluetooth.disconnected) { paired in
            DeviceRow(id: "bt:\(paired.id)", name: paired.name, symbol: paired.symbol, selected: false,
                      trailing: model.bluetooth.connecting.contains(paired.id) ? "Connecting…"
                        : model.bluetooth.proximity.battery(forName: paired.name).flatMap { $0.buds ?? $0.main }.map { "\($0)%" }) {
                model.bluetooth.connect(paired, devices: model.devices)
            }
        }
    }
}

/// One output, plus its listening modes when expanded. Like the system menu,
/// only the selected device offers them, and clicking it opens and closes them.
private struct OutputItem: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel
    let device: AudioDevice

    private var selected: Bool { device.id == model.devices.defaultOutputID }
    private var details: BluetoothDetails? { model.bluetooth.details(for: device) }
    private var hasModes: Bool { selected && !(details?.modes.isEmpty ?? true) }
    private var expanded: Bool { hasModes && panel.expandedDevice == device.uid }

    private func setExpanded(_ value: Bool) {
        Motion.animate { panel.expandedDevice = value ? device.uid : nil }
    }

    var body: some View {
        let battery = details?.battery
        DeviceRow(id: "out:\(device.uid)", name: device.name, symbol: device.symbol, selected: selected,
                  trailing: (battery?.buds ?? battery?.main).map { "\($0)%" },
                  chevron: hasModes ? expanded : nil,
                  expand: expandAction, action: activate)
        if expanded, let details {
            ListeningModes(device: device, details: details)
                .transition(.opacity)
        }
    }

    private var expandAction: (@MainActor (Bool) -> Void)? {
        guard hasModes else { return nil }
        return { value in setExpanded(value) }
    }

    private func activate() {
        if hasModes { setExpanded(!expanded) } else { model.devices.setDefaultOutput(device) }
    }
}

struct InputList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let devices = model.devices
        if devices.inputDevices.isEmpty { PlaceholderRow(text: "No Input Devices") }
        ForEach(devices.inputDevices) { device in
            DeviceRow(id: "in:\(device.uid)", name: device.name, symbol: device.symbol,
                      selected: device.id == devices.defaultInputID, trailing: nil) {
                devices.setDefaultInput(device)
            }
        }
    }
}

/// The system Sound menu's device row: the device's glyph in a 26 pt circle,
/// accent when selected, battery on the right.
struct DeviceRow: View {
    let id: String
    let name: String
    let symbol: String
    let selected: Bool
    let trailing: String?
    /// nil for no chevron, otherwise whether it points down.
    var chevron: Bool?
    var expand: (@MainActor (Bool) -> Void)?
    let action: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 8) {
            DeviceCircle(symbol: symbol, selected: selected)
            Text(name).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            if let trailing {
                Text(trailing).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            if let chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(chevron ? 90 : 0))
            }
        }
        .menuRow(id, height: Metrics.deviceRowHeight, expand: expand, action: action)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct DeviceCircle: View {
    @Environment(\.menuHighlighted) private var lit
    let symbol: String
    let selected: Bool

    var body: some View {
        ZStack {
            Circle().fill(fill)
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(glyph)
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }

    private var fill: Color {
        switch (selected, lit) {
        case (true, false): Color(nsColor: .controlAccentColor)
        case (true, true): .white
        case (false, true): .white.opacity(0.15)
        case (false, false): .primary.opacity(0.1)
        }
    }

    private var glyph: Color {
        switch (selected, lit) {
        case (true, false): .white
        case (true, true): Color(nsColor: .controlAccentColor)
        case (false, true): .white
        case (false, false): .primary.opacity(0.75)
        }
    }
}

/// Listening Mode list under the selected AirPods, like the system menu's submenu.
private struct ListeningModes: View {
    @Environment(AppModel.self) private var model
    let device: AudioDevice
    let details: BluetoothDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Listening Mode")
                .font(.system(size: NSFont.smallSystemFontSize, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, Metrics.inset + 34)
                .frame(height: 22)
            ForEach(details.modes) { mode in
                let on = details.listeningMode == mode
                HStack(spacing: 0) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .opacity(on ? 1 : 0)
                        .frame(width: 34, alignment: .center)
                    Text(mode.title)
                    Spacer(minLength: 0)
                }
                .menuRow("mode:\(mode.rawValue)") { model.bluetooth.setListeningMode(mode, for: device) }
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.bottom, 2)
    }
}
