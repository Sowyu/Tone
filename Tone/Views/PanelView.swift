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
                      trailing: model.bluetooth.connecting.contains(paired.id) ? "Connecting…" : nil,
                      battery: model.bluetooth.battery(forName: paired.name)) {
                model.bluetooth.connect(paired, devices: model.devices)
            }
        }
    }
}

/// One output, plus the AirPods section when expanded. Like the system menu,
/// only the selected AirPods offer it, and clicking the row opens and closes it.
private struct OutputItem: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel
    let device: AudioDevice

    private var selected: Bool { device.id == model.devices.defaultOutputID }
    private var details: BluetoothDetails? { model.bluetooth.details(for: device) }
    private var hasSection: Bool { selected && details?.isAirPods == true }
    private var expanded: Bool { hasSection && panel.expandedDevice == device.uid }

    private func setExpanded(_ value: Bool) {
        Motion.animate { panel.expandedDevice = value ? device.uid : nil }
    }

    var body: some View {
        DeviceRow(id: "out:\(device.uid)", name: device.name, symbol: details?.symbol ?? device.symbol, selected: selected,
                  trailing: nil, battery: model.bluetooth.battery(forName: device.name, details: details),
                  chevron: hasSection ? expanded : nil,
                  expand: expandAction, action: activate)
            .background(expanded ? Color.primary.opacity(0.04) : .clear)
        if expanded {
            AirPodsSection(device: device, details: details ?? BluetoothDetails())
                .transition(.opacity)
        }
    }

    private var expandAction: (@MainActor (Bool) -> Void)? {
        guard hasSection else { return nil }
        return { value in setExpanded(value) }
    }

    private func activate() {
        if hasSection { setExpanded(!expanded) } else { model.devices.setDefaultOutput(device) }
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
/// accent when selected. AirPods show each bud and the case under the name,
/// other devices show one level on the right with a battery gauge.
struct DeviceRow: View {
    let id: String
    let name: String
    let symbol: String
    let selected: Bool
    let trailing: String?
    var battery: BatteryLevel? = nil
    /// nil for no chevron, otherwise whether it points down.
    var chevron: Bool?
    var expand: (@MainActor (Bool) -> Void)?
    let action: @MainActor () -> Void

    private var budGlyph: String? { Self.budGlyph(for: symbol) }

    var body: some View {
        let under = budGlyph == nil ? [] : budParts
        HStack(spacing: 8) {
            DeviceCircle(symbol: symbol, selected: selected)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1).truncationMode(.tail)
                if !under.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(under, id: \.glyph) { part in
                            HStack(spacing: 3) {
                                Image(systemName: part.glyph).symbolRenderingMode(.hierarchical)
                                Text("\(part.level)%").monospacedDigit()
                            }
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            if let trailing {
                Text(trailing).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize()
            } else if budGlyph == nil, let battery = battery?.shown {
                HStack(spacing: 5) {
                    Text("\(battery)%").monospacedDigit().foregroundStyle(.secondary)
                    BatteryGauge(level: battery)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Battery \(battery)%")
            }
            if let chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(chevron ? 90 : 0))
            }
        }
        .padding(.vertical, under.isEmpty ? 0 : 3)
        .menuRow(id, height: Metrics.deviceRowHeight, expand: expand, action: action)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Left bud, right bud and case, each with its own glyph like the system menu.
    /// Buds at the same level share one glyph of both buds.
    private var budParts: [(glyph: String, level: Int)] {
        guard let battery, let right = budGlyph else { return [] }
        var parts: [(glyph: String, level: Int)] = []
        switch (battery.left, battery.right) {
        case let (l?, r?) where l == r: parts.append((symbol, l))
        case let (l, r):
            if let l { parts.append((Self.glyph(symbol + ".left", fallback: right.replacingOccurrences(of: ".right", with: ".left")), l)) }
            if let r { parts.append((right, r)) }
        }
        if parts.isEmpty, let main = battery.main { parts.append((right, main)) }
        if let c = battery.caseLevel {
            parts.append((Self.glyph(symbol + ".chargingcase.wireless.fill", fallback: "airpods.chargingcase.wireless.fill"), c))
        }
        return parts
    }

    private static func glyph(_ name: String, fallback: String) -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : fallback
    }

    /// One bud of the same AirPods, as the system menu draws it. nil for anything else.
    static func budGlyph(for symbol: String) -> String? {
        guard symbol.hasPrefix("airpod"), !symbol.contains("max") else { return nil }
        let right = symbol + ".right"
        if NSImage(systemSymbolName: right, accessibilityDescription: nil) != nil { return right }
        return symbol.contains("pro") ? "airpodpro.right" : "airpod.right"
    }
}

/// The menu bar battery's shape: a pill filled to the level with a nub on the right.
private struct BatteryGauge: View {
    let level: Int

    var body: some View {
        HStack(spacing: 1) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(.secondary.opacity(0.4))
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(.secondary)
                            .frame(width: geo.size.width * CGFloat(min(max(level, 0), 100)) / 100)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .frame(width: 21, height: 11)
            RoundedRectangle(cornerRadius: 1).fill(.secondary.opacity(0.4)).frame(width: 1.5, height: 4)
        }
    }
}

private struct DeviceCircle: View {
    let symbol: String
    let selected: Bool

    var body: some View {
        ZStack {
            Circle().fill(fill)
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(glyph)
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }

    private var fill: Color { selected ? Color(nsColor: .controlAccentColor) : .primary.opacity(0.1) }
    private var glyph: Color { selected ? .white : .primary.opacity(0.75) }
}

/// The system menu's AirPods section, on a lighter rounded band under the device row.
/// Listening mode and Conversation Awareness go over the AirPods' own control
/// channel (AirPodsLink). Spatial Audio shows Not Available, as the system menu
/// does on a Mac.
private struct AirPodsSection: View {
    @Environment(AppModel.self) private var model
    let device: AudioDevice
    let details: BluetoothDetails

    private var link: AirPodsLink? { model.bluetooth.link(for: device) }

    /// The system's order, with Off only while it's the current mode.
    private var modes: [ListeningMode] {
        [.off, .transparency, .adaptive, .noiseCancellation].filter { mode in
            switch mode {
            case .off: link?.listeningMode == .off
            case .adaptive: details.hasAdaptive
            default: true
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Listening Mode")
            ForEach(modes) { mode in
                OptionRow(id: "mode:\(mode.rawValue)", glyph: Self.glyph(for: mode), title: mode.title,
                          on: link?.listeningMode == mode) {
                    link?.setListeningMode(mode)
                }
            }
            separator
            header("Spatial Audio")
            OptionRow(id: "spatial", glyph: .system("person.spatialaudio.fill"), title: "Not Available", on: false, action: nil)
            separator
            header("Conversation Awareness")
            ForEach([false, true], id: \.self) { value in
                OptionRow(id: "ca:\(value)", glyph: .system("person.wave.2.fill"), title: value ? "On" : "Off",
                          on: link?.conversationAwareness == value) {
                    link?.setConversationAwareness(value)
                }
            }
        }
        // Measured on the system menu: 17 pt from the band's top to the first
        // header's capitals, 18 pt from the last row's middle to its bottom.
        .padding(.top, 9.5)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.12))
                .padding(.horizontal, Metrics.highlightInset)
        )
        // 8.5 pt between the band and the device circles above and below.
        .padding(.top, 2.5)
        .padding(.bottom, 5.5)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Metrics.inset)
            .frame(height: Metrics.rowHeight)
            .accessibilityAddTraits(.isHeader)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.13))
            .frame(height: 1)
            .padding(.horizontal, 8 + Metrics.highlightInset)
            .padding(.vertical, 4.5)
    }

    /// The system's glyphs. Adaptive's is a private symbol, so it falls back to sparkles.
    static func glyph(for mode: ListeningMode) -> OptionRow.Glyph {
        switch mode {
        case .off: .system("person.fill")
        case .transparency: .system("person.crop.circle.dashed")
        case .adaptive: .privateSymbol("person.and.sparkles.fill", fallback: "sparkles")
        case .noiseCancellation: .system("person.crop.circle")
        }
    }
}

/// A row in the AirPods section: checkmark column, glyph, title. Without an
/// action it's greyed like the system's unavailable items.
private struct OptionRow: View {
    enum Glyph {
        case system(String)
        case privateSymbol(String, fallback: String)
    }

    let id: String
    let glyph: Glyph
    let title: String
    let on: Bool
    let action: (@MainActor () -> Void)?

    var body: some View {
        let row = HStack(spacing: 0) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .opacity(on ? 1 : 0)
                .frame(width: 23)
            image
                .font(.system(size: 14))
                .frame(width: 36)
            Text(title)
            Spacer(minLength: 0)
        }
        if let action {
            row.menuRow(id, action: action)
                .accessibilityAddTraits(on ? .isSelected : [])
        } else {
            row.foregroundStyle(.tertiary)
                .padding(.horizontal, Metrics.inset)
                .frame(height: Metrics.rowHeight)
                .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var image: some View {
        switch glyph {
        case let .system(name):
            Image(systemName: name)
        case let .privateSymbol(name, fallback):
            if let image = Self.privateSymbol(name) {
                Image(nsImage: image).renderingMode(.template)
            } else {
                Image(systemName: fallback)
            }
        }
    }

    private static func privateSymbol(_ name: String) -> NSImage? {
        let selector = NSSelectorFromString("imageWithPrivateSystemSymbolName:")
        guard NSImage.responds(to: selector) else { return nil }
        let image = (NSImage.self as AnyObject).perform(selector, with: name)?.takeUnretainedValue() as? NSImage
        return image?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
    }
}
