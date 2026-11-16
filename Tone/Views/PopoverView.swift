import SwiftUI

/// Fills the transparent panel window. Nothing renders while the panel is closed,
/// so marquees and animations don't run in the background.
struct PopoverRoot: View {
    @Environment(AppModel.self) private var model
    let onSettings: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.isPanelOpen {
                PopoverView(onSettings: onSettings)
                    .frame(width: Metrics.width)
            }
        }
        .padding(.horizontal, PanelController.margin)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onExitCommand(perform: onClose)
    }
}

struct PopoverView: View {
    @Environment(AppModel.self) private var model
    let onSettings: () -> Void
    @FocusState private var settingsFocused: Bool

    var body: some View {
        let devices = model.devices
        let volume = Binding(get: { Double(devices.masterVolume) }, set: { devices.setMasterVolume(Float($0)) })
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sound").font(.system(size: 13, weight: .bold))
                Spacer()
                Text(volume.wrappedValue.percent)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: volume.wrappedValue))
            }
            .padding(.horizontal, Metrics.inset)
            .padding(.top, 12)

            SpeakerSlider(value: volume, label: "Output volume")
                .disabled(!devices.canSetVolume)
                .padding(.horizontal, Metrics.inset)
                .padding(.top, 6)
                .padding(.bottom, 10)

            ForEach(PopoverSection.allCases) { section in
                InsetDivider()
                AccordionSection(section: section)
            }

            InsetDivider()
            Button(action: onSettings) {
                HStack {
                    Text("Sound Settings…")
                    Spacer()
                    Text("⌘ ,").foregroundStyle(.tertiary)
                }
                .padding(.horizontal, Metrics.inset)
                .frame(height: Metrics.sectionRowHeight)
                .hoverHighlight(focused: settingsFocused)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .focusRow($settingsFocused, action: onSettings)
            .padding(.bottom, 4)
        }
        .font(.system(size: 13))
        .panelSurface()
    }
}
