import AppKit
import SwiftUI

// MARK: Lists

struct NowPlayingList: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel

    var body: some View {
        let sessions = model.nowPlaying.sessions
        if sessions.isEmpty { PlaceholderRow(text: "Not Playing") }
        ForEach(sessions) { session in
            let rowID = "np:\(session.id)"
            NowPlayingRow(session: session, expanded: panel.expandedRow == rowID)
                .menuRow(rowID, height: 48, expand: { open in
                    if open != (panel.expandedRow == rowID) { panel.toggleRow(rowID) }
                }) { panel.toggleRow(rowID) }
                .contextMenu { AppContextMenu(key: session.id, movable: false) }
            if panel.expandedRow == rowID {
                AppControls(key: session.id).transition(.opacity)
            }
        }
    }
}

struct ApplicationList: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel

    var body: some View {
        if model.permission.status == .denied {
            PlainRow(id: "permission", title: "Allow System Audio Recording…") { model.permission.openSystemSettings() }
        }
        let keys = model.applicationKeys
        if keys.isEmpty { PlaceholderRow(text: "No Apps Playing Audio") }
        ForEach(keys, id: \.self) { key in
            let rowID = "app:\(key)"
            let expanded = panel.expandedRow == rowID
            AppRow(key: key, expanded: expanded)
                .menuRow(rowID, height: 26, expand: { open in
                    if open != expanded { panel.toggleRow(rowID) }
                }) { panel.toggleRow(rowID) }
                .contextMenu { AppContextMenu(key: key, movable: true) }
                .accessibilityValue(expanded ? "expanded" : "collapsed")
            if expanded {
                AppControls(key: key).transition(.opacity)
            }
        }
    }
}

// MARK: Rows

/// Icon, name, then the volume right-aligned against the chevron.
struct AppRow: View {
    @Environment(AppModel.self) private var model
    let key: String
    let expanded: Bool

    var body: some View {
        let volume = model.settings(key).volume
        HStack(spacing: 8) {
            Image(nsImage: model.icon(key))
                .resizable()
                .interpolation(.high)
                .frame(width: Metrics.appIcon, height: Metrics.appIcon)
                .opacity(model.processes.apps[key] == nil ? 0.5 : 1)
            Text(model.displayName(key))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                // The open band shows the volume, so the row drops it, as in the concept.
                if !expanded {
                    Text(volume.percent)
                        .monospacedDigit()
                        .foregroundStyle(volume > 1.0001 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                }
                Chevron(down: expanded)
            }
            .fixedSize()
        }
    }
}

struct Chevron: View {
    let down: Bool
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(down ? 90 : 0))
            .frame(width: 10)
            .accessibilityHidden(true)
    }
}

/// Artwork with the source app's icon, a title that scrolls when it's too long,
/// and play/pause and next buttons. Reads the session live, so it updates while open.
struct NowPlayingRow: View {
    @Environment(AppModel.self) private var model
    let session: NowPlayingSession
    let expanded: Bool

    var body: some View {
        HStack(spacing: 10) {
            Artwork(image: session.artwork, badge: model.icon(session.id))
            VStack(alignment: .leading, spacing: 1) {
                MarqueeText(text: session.title.isEmpty ? model.displayName(session.id) : session.title,
                            font: .system(size: NSFont.systemFontSize, weight: .semibold), isActive: model.isMenuOpen)
                if !session.subtitle.isEmpty {
                    MarqueeText(text: session.subtitle, font: .system(size: NSFont.smallSystemFontSize + 1),
                                isActive: model.isMenuOpen)
                        .foregroundStyle(.secondary)
                }
            }
            .layoutPriority(-1)
            HStack(spacing: 2) {
                MediaButton(symbol: session.isPlaying ? "pause.fill" : "play.fill", size: 16,
                            label: session.isPlaying ? "Pause" : "Play") { model.nowPlaying.togglePlayPause(session) }
                MediaButton(symbol: "forward.fill", size: 13, label: "Next Track") { model.nowPlaying.next(session) }
            }
            .opacity(session.isCurrent ? 1 : 0.5)
            .disabled(!session.isCurrent)
        }
        .padding(.trailing, -5)
    }
}

private struct MediaButton: View {
    let symbol: String
    let size: CGFloat
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Album art with the source app's icon on its corner, as Control Center shows it.
private struct Artwork: View {
    let image: NSImage?
    let badge: NSImage

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.quaternary)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            Image(nsImage: badge)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
                .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                .offset(x: 4, y: 4)
        }
        .padding(.trailing, 4)
        .accessibilityHidden(true)
    }
}

/// Right-click menu of an app row: keep, hide, reorder.
struct AppContextMenu: View {
    @Environment(AppModel.self) private var model
    let key: String
    let movable: Bool

    var body: some View {
        Toggle("Keep in Menu", isOn: Binding(get: { model.store.state.pinned.contains(key) },
                                             set: { _ in model.togglePinned(key) }))
        Button("Reset Volume") { model.resetVolume(key) }
        if movable {
            Divider()
            let keys = model.applicationKeys
            let index = keys.firstIndex(of: key) ?? 0
            Button("Move Up") { Motion.animate { model.moveApp(key, by: -1) } }.disabled(index == 0)
            Button("Move Down") { Motion.animate { model.moveApp(key, by: 1) } }.disabled(index >= keys.count - 1)
        }
        Divider()
        Button("Hide from Menu") { Motion.animate { model.hide(key) } }
    }
}

// MARK: Controls band

/// The lighter full-width band under an expanded row: Volume, Equalizer, Preset,
/// and the row actions. The equalizer opens in a popover to the left.
struct AppControls: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel
    let key: String

    var body: some View {
        let settings = model.settings(key)
        let eqShown = Binding(get: { panel.eqTarget == key }, set: { shown in
            if !shown, panel.eqTarget == key { panel.eqTarget = nil }
        })
        VStack(alignment: .leading, spacing: 0) {
            VolumeHeader(title: "Volume", accessibilityLabel: "\(model.displayName(key)) Volume",
                         value: Binding(get: { model.settings(key).volume }, set: { model.setVolume(key, $0) }),
                         range: 0...model.overdriveLimit)
                .padding(.horizontal, Metrics.inset)
                .padding(.top, 8)
                .padding(.bottom, 8)

            BandDivider()
            HStack {
                Text("Equalizer")
                Spacer()
                Toggle("Equalizer", isOn: Binding(get: { model.settings(key).eqEnabled },
                                                  set: { model.setEQEnabled(key, $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            .padding(.horizontal, Metrics.inset)
            .frame(height: 32)

            BandDivider()
            HStack(spacing: 6) {
                Text("Preset")
                Button {
                    Motion.animate { panel.eqTarget = panel.eqTarget == key ? nil : key }
                } label: {
                    Image(systemName: "chart.xyaxis.line")
                        .foregroundStyle(panel.eqTarget == key ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show Equalizer")
                .accessibilityLabel("Show Equalizer")
                Spacer(minLength: 8)
                PresetMenu(key: key, current: settings.presetName)
            }
            .padding(.horizontal, Metrics.inset)
            .frame(height: 32)
            // Anchored to the full-width row so the arrow points at the panel's left edge.
            .popover(isPresented: eqShown, arrowEdge: .leading) {
                EQPanel(key: key).environment(model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05))
        .padding(.vertical, 2)
    }
}

private struct BandDivider: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1).padding(.horizontal, Metrics.inset)
    }
}

/// The preset's name with an up-down chevron; opens a native menu of presets.
/// The name truncates before it can reach the chevron.
struct PresetMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelState.self) private var panel
    let key: String
    let current: String

    var body: some View {
        Menu {
            ForEach(PresetStore.builtIn) { item($0) }
            if !model.presets.custom.isEmpty {
                Divider()
                ForEach(model.presets.custom) { item($0) }
            }
            Divider()
            Button("Save as Preset…", action: saveAsPreset)
        } label: {
            HStack(spacing: 6) {
                Text(current)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 150, alignment: .trailing)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.quaternary))
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Preset")
        .accessibilityValue(current)
    }

    private func item(_ preset: EQPreset) -> some View {
        Toggle(preset.name, isOn: Binding(get: { preset.name == current }, set: { _ in
            Motion.animate { model.applyPreset(key, preset) }
        }))
    }

    private func saveAsPreset() {
        let model = self.model
        let key = self.key
        // The panel floats above alerts, so it closes first, as a menu would.
        panel.close()
        let alert = NSAlert()
        alert.messageText = "Save as Preset"
        alert.informativeText = "Enter a name for this equalizer setting."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 228, height: 22))
        field.placeholderString = "Preset Name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.presets.save(name: name, eq: model.settings(key).eq) {
            model.store.update(key) { $0.presetName = name }
        } else {
            NSSound.beep()
        }
    }
}

// MARK: Marquee

/// One line of text that scrolls when it doesn't fit, so a long title never
/// widens the panel. Static under Reduce Motion and while the panel is closed.
struct MarqueeText: View {
    let text: String
    let font: Font
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var scrolling = false
    private let gap: CGFloat = 32
    private let pointsPerSecond: CGFloat = 30

    private var scrolls: Bool { textWidth > boxWidth + 1 && isActive && !reduceMotion }

    var body: some View {
        Text(text).font(font).lineLimit(1).hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { boxWidth = $0 }
            .overlay(alignment: .leading) {
                if scrolls {
                    HStack(spacing: gap) {
                        Text(text).font(font).fixedSize()
                        Text(text).font(font).fixedSize()
                    }
                    .offset(x: scrolling ? -(textWidth + gap) : 0)
                    .animation(.linear(duration: Double((textWidth + gap) / pointsPerSecond)).delay(1.5)
                        .repeatForever(autoreverses: false), value: scrolling)
                    .onAppear { scrolling = true }
                } else {
                    Text(text).font(font).lineLimit(1)
                }
            }
            .background(
                Text(text).font(font).fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { textWidth = $0 }
            )
            .clipped()
            .id(text)
            .accessibilityLabel(text)
    }
}
