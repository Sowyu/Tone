import AppKit
import SwiftUI

// MARK: Lists

struct ApplicationList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rows = model.applicationRows
        VStack(spacing: 0) {
            if model.permission.status == .denied { PermissionBanner() }
            if rows.isEmpty { EmptyHint(text: "No apps are playing audio") }
            ForEach(rows) { row in
                AppRow(item: row)
                    .onDrop(of: [.text], delegate: ReorderDelegate(target: row.id, model: model) { model.moveApp($0, to: $1) })
            }
        }
    }
}

struct NowPlayingList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rows = model.nowPlayingRows
        VStack(spacing: 0) {
            switch model.nowPlaying.availability {
            case .missingTool:
                EmptyHint(text: "Install media-control to see what's playing:\nbrew install media-control")
                    .textSelection(.enabled)
            case .failed(let reason):
                EmptyHint(text: "Now Playing is unavailable (\(reason)).")
            case .starting, .available:
                if rows.isEmpty { EmptyHint(text: "Nothing is playing") }
            }
            ForEach(rows) { session in
                NowPlayingRow(session: session)
                    .onDrop(of: [.text], delegate: ReorderDelegate(target: session.id, model: model) { model.moveNowPlaying($0, to: $1) })
            }
        }
    }
}

struct PermissionBanner: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text("Tone needs System Audio Recording access to change app volumes.")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings") { model.permission.openSystemSettings() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.yellow.opacity(0.12)))
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }
}

/// Live drag-to-reorder: rows swap as the dragged row passes over them.
struct ReorderDelegate: DropDelegate {
    let target: String
    let model: AppModel
    let move: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged = model.dragging, dragged != target else { return }
        Motion.animate { move(dragged, target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        model.dragging = nil
        return true
    }
}

// MARK: Rows

struct AppRow: View {
    @Environment(AppModel.self) private var model
    let item: AppRowItem
    @FocusState private var focused: Bool

    private var rowID: String { "app:\(item.id)" }
    private var expanded: Bool { model.expandedRow == rowID }

    var body: some View {
        let settings = model.settings(item.id)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: model.icon(item.id))
                    .resizable()
                    .frame(width: 22, height: 22)
                    .opacity(item.isRunning ? 1 : 0.5)
                Text(item.name).lineLimit(1)
                Spacer(minLength: 4)
                if settings.eqEnabled {
                    Image(systemName: "slider.vertical.3")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Text("\(Int((settings.volume * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .rowHighlight(active: expanded, focused: focused)
            .onTapGesture(perform: toggle)
            .focusRow($focused, action: toggle)
            .onDrag {
                model.dragging = item.id
                return NSItemProvider(object: item.id as NSString)
            }
            .contextMenu { RowContextMenu(key: item.id, canMove: true) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows volume and equalizer for \(item.name)")

            if expanded {
                AppControlPanel(key: item.id)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .opacity(model.dragging == item.id ? 0.55 : 1)
    }

    private func toggle() {
        model.dragging = nil
        Motion.animate {
            model.expandedRow = expanded ? nil : rowID
            if !expanded, model.eqTarget != nil, model.eqTarget != item.id { model.eqTarget = nil }
        }
    }
}

struct NowPlayingRow: View {
    @Environment(AppModel.self) private var model
    let session: NowPlayingSession
    @FocusState private var focused: Bool

    private var rowID: String { "np:\(session.id)" }
    private var expanded: Bool { model.expandedRow == rowID }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Artwork(image: session.artwork, badge: model.icon(session.id))
                VStack(alignment: .leading, spacing: 1) {
                    MarqueeText(text: session.title, font: .system(size: 13, weight: .bold))
                    if !session.subtitle.isEmpty {
                        Text(session.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                HStack(spacing: 2) {
                    MediaButton(symbol: session.isPlaying ? "pause.fill" : "play.fill",
                                label: session.isPlaying ? "Pause" : "Play") { model.nowPlaying.togglePlayPause(session) }
                    MediaButton(symbol: "forward.fill", label: "Next track") { model.nowPlaying.next(session) }
                }
                .disabled(!session.isCurrent)
                .help(session.isCurrent ? "" : "Only the active player can be controlled")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .rowHighlight(active: expanded, focused: focused)
            .onTapGesture(perform: toggle)
            .focusRow($focused, action: toggle)
            .onDrag {
                model.dragging = session.id
                return NSItemProvider(object: session.id as NSString)
            }
            .contextMenu { RowContextMenu(key: session.id, canMove: false) }

            if expanded {
                AppControlPanel(key: session.id)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .opacity(model.dragging == session.id ? 0.55 : 1)
    }

    private func toggle() {
        model.dragging = nil
        Motion.animate {
            model.expandedRow = expanded ? nil : rowID
            if !expanded, model.eqTarget != nil, model.eqTarget != session.id { model.eqTarget = nil }
        }
    }
}

private struct MediaButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(hovering ? 0.12 : 0)))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
    }
}

/// Rounded-square artwork with the source app's icon as a round badge.
struct Artwork: View {
    let image: NSImage?
    let badge: NSImage

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.white.opacity(0.1)
                        Image(systemName: "music.note").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Image(nsImage: badge)
                .resizable()
                .frame(width: 16, height: 16)
                .background(Circle().fill(.black.opacity(0.55)).padding(-1.5))
                .clipShape(Circle())
                .offset(x: 4, y: 4)
        }
        .padding(.trailing, 4)
        .padding(.bottom, 4)
        .accessibilityHidden(true)
    }
}

struct RowContextMenu: View {
    @Environment(AppModel.self) private var model
    let key: String
    let canMove: Bool

    var body: some View {
        Toggle("Always Show", isOn: Binding(get: { model.store.state.pinned.contains(key) },
                                            set: { _ in model.togglePinned(key) }))
        Button("Reset Volume") { model.resetVolume(key) }
        Button("Hide") { Motion.animate { model.hide(key) } }
        if canMove {
            Divider()
            Button("Move Up") { Motion.animate { model.moveApp(key, by: -1) } }
            Button("Move Down") { Motion.animate { model.moveApp(key, by: 1) } }
        }
    }
}

// MARK: Inline control panel

struct AppControlPanel: View {
    @Environment(AppModel.self) private var model
    let key: String
    @FocusState private var eqFocused: Bool

    var body: some View {
        let s = model.settings(key)
        let volume = Binding(get: { model.settings(key).volume }, set: { model.setVolume(key, $0) })
        let eqOn = Binding(get: { model.settings(key).eqEnabled }, set: { on in
            model.setEQEnabled(key, on)
            if on { Motion.animate { model.eqTarget = key } }
        })
        VStack(spacing: 6) {
            if model.permission.status == .denied { PermissionBanner() }
            HStack(spacing: 8) {
                Image(systemName: SpeakerSymbol.name(volume: min(s.volume, 1), muted: false))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .leading)
                ToneSlider(value: volume, range: 0...model.overdriveLimit, mark: model.overdriveLimit > 1 ? 1 : nil,
                           accessibilityLabel: "\(model.displayName(key)) volume",
                           accessibilityValue: "\(Int((s.volume * 100).rounded())) percent")
                Text("\(Int((s.volume * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(s.volume > 1.001 ? Color.orange : .secondary)
                    .frame(width: 40, alignment: .trailing)
            }

            HStack {
                Button(action: toggleEQPanel) {
                    HStack(spacing: 4) {
                        Text("Equalizer")
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .opacity(model.eqTarget == key ? 1 : 0.6)
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 4)
                    .rowHighlight(active: model.eqTarget == key, focused: eqFocused)
                }
                .buttonStyle(.plain)
                .focusRow($eqFocused, action: toggleEQPanel)
                .accessibilityHint("Opens the equalizer panel")
                Spacer()
                Toggle("Equalizer", isOn: eqOn)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }

            HStack {
                Text("Preset").padding(.leading, 4)
                Spacer()
                PresetMenu(key: key)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
    }

    private func toggleEQPanel() {
        Motion.animate { model.eqTarget = model.eqTarget == key ? nil : key }
    }
}

struct PresetMenu: View {
    @Environment(AppModel.self) private var model
    let key: String

    var body: some View {
        let current = model.settings(key).presetName
        Menu {
            ForEach(PresetStore.builtIn) { preset in item(preset, current: current) }
            if !model.presets.custom.isEmpty {
                Divider()
                Menu("Custom Presets") {
                    ForEach(model.presets.custom) { preset in item(preset, current: current) }
                }
            }
            Divider()
            Button("Save as Preset…", action: saveAsPreset)
        } label: {
            HStack(spacing: 4) {
                Text(current)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Preset, \(current)")
    }

    @ViewBuilder private func item(_ preset: EQPreset, current: String) -> some View {
        Button {
            Motion.animate { model.applyPreset(key, preset) }
        } label: {
            if preset.name == current { Label(preset.name, systemImage: "checkmark") } else { Text(preset.name) }
        }
    }

    private func saveAsPreset() {
        let alert = NSAlert()
        alert.messageText = "Save as Preset"
        alert.informativeText = "Name this equalizer setting."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "My Preset"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let eq = model.settings(key).eq
        let name = field.stringValue
        if model.presets.save(name: name, eq: eq) {
            model.store.update(key) { $0.presetName = name.trimmingCharacters(in: .whitespacesAndNewlines) }
        } else {
            NSSound.beep()
        }
    }
}

// MARK: Marquee

/// Single-line text that scrolls smoothly when it doesn't fit. Static under Reduce Motion.
struct MarqueeText: View {
    let text: String
    let font: Font
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var scrolling = false
    private let gap: CGFloat = 32
    private let speed: CGFloat = 30

    private var overflows: Bool { textWidth > boxWidth + 1 && !Motion.reduce }

    var body: some View {
        Text(text).font(font).lineLimit(1).hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { boxWidth = $0 }
            .overlay(alignment: .leading) {
                if overflows {
                    HStack(spacing: gap) {
                        Text(text).font(font).fixedSize()
                        Text(text).font(font).fixedSize()
                    }
                    .offset(x: scrolling ? -(textWidth + gap) : 0)
                    .animation(.linear(duration: Double((textWidth + gap) / speed)).delay(1.5).repeatForever(autoreverses: false),
                               value: scrolling)
                    .onAppear { scrolling = true }
                    .onDisappear { scrolling = false }
                } else {
                    Text(text).font(font).lineLimit(1).truncationMode(.tail)
                }
            }
            .background(
                Text(text).font(font).fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { textWidth = $0 }
            )
            .mask(
                LinearGradient(stops: overflows ? [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                                   .init(color: .black, location: 0.92), .init(color: .clear, location: 1)]
                                                : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            )
            .clipped()
            .id(text)
            .accessibilityLabel(text)
    }
}
