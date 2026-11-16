import AppKit
import SwiftUI

// MARK: Lists

struct ApplicationList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rows = model.applicationRows
        VStack(spacing: 0) {
            if model.permission.status == .denied { PermissionNotice() }
            if rows.isEmpty { EmptyHint(text: "No apps are playing audio") }
            ForEach(rows) { row in
                AppRow(item: row)
                    .onDrop(of: [.text], delegate: ReorderDelegate(target: row.id, model: model) { model.moveApp($0, to: $1) })
            }
        }
        .padding(.bottom, 4)
    }
}

struct NowPlayingList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rows = model.nowPlayingRows
        VStack(spacing: 0) {
            switch model.nowPlaying.availability {
            case .missingTool: EmptyHint(text: "Install media-control to see what's playing.")
            case .failed: EmptyHint(text: "Now Playing isn't available.")
            case .starting, .available: if rows.isEmpty { EmptyHint(text: "Not Playing") }
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, session in
                // Full-width separators between rows, none under an expanded row.
                if index > 0, model.expandedRow != "np:\(rows[index - 1].id)" { Divider() }
                NowPlayingRow(session: session)
                    .onDrop(of: [.text], delegate: ReorderDelegate(target: session.id, model: model) { model.moveNowPlaying($0, to: $1) })
            }
        }
    }
}

struct PermissionNotice: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Tone needs permission to record system audio to change app volumes.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Privacy & Security Settings…") { model.permission.openSystemSettings() }
                .buttonStyle(.link)
        }
        .font(.system(size: 12))
        .padding(.horizontal, Metrics.inset)
        .padding(.bottom, 8)
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

/// Shared row behaviour: click or Return expands the controls band, drag
/// reorders, right-click opens the native context menu.
private struct ExpandableRow<Header: View>: View {
    @Environment(AppModel.self) private var model
    let key: String
    let rowID: String
    let movable: Bool
    var highlightInset = true
    @ViewBuilder let header: Header
    @FocusState private var focused: Bool

    private var expanded: Bool { model.expandedRow == rowID }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Metrics.inset)
                .modifier(RowBackground(inset: highlightInset, focused: focused))
                .onTapGesture(perform: toggle)
                .focusRow($focused, action: toggle)
                .onDrag {
                    model.dragging = key
                    return NSItemProvider(object: key as NSString)
                }
                .contextMenu { RowContextMenu(key: key, movable: movable) }
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(expanded ? "expanded" : "collapsed")

            if expanded {
                AppControls(key: key)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .opacity(model.dragging == key ? 0.5 : 1)
    }

    private func toggle() {
        model.dragging = nil
        Motion.animate {
            model.expandedRow = expanded ? nil : rowID
            model.eqTarget = nil
        }
    }
}

/// Inset rounded highlight for compact rows, full-width tint for tall ones.
private struct RowBackground: ViewModifier {
    let inset: Bool
    let focused: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        if inset {
            content.hoverHighlight(focused: focused)
        } else {
            content
                .contentShape(Rectangle())
                .background(Color.primary.opacity(hovering || focused ? 0.05 : 0))
                .onHover { hovering = $0 }
        }
    }
}

struct AppRow: View {
    @Environment(AppModel.self) private var model
    let item: AppRowItem

    var body: some View {
        let volume = model.settings(item.id).volume
        ExpandableRow(key: item.id, rowID: "app:\(item.id)", movable: true) {
            HStack(spacing: 8) {
                Image(nsImage: model.icon(item.id))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Metrics.appIcon, height: Metrics.appIcon)
                    .opacity(item.isRunning ? 1 : 0.5)
                Text(item.name).lineLimit(1)
                Spacer(minLength: 4)
                Text(volume.percent)
                    .monospacedDigit()
                    .foregroundStyle(volume > 1.0001 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            }
            .frame(height: 28)
            .accessibilityElement(children: .combine)
        }
    }
}

struct NowPlayingRow: View {
    @Environment(AppModel.self) private var model
    let session: NowPlayingSession

    var body: some View {
        ExpandableRow(key: session.id, rowID: "np:\(session.id)", movable: false, highlightInset: false) {
            HStack(spacing: 14) {
                Artwork(image: session.artwork, badge: model.icon(session.id))
                VStack(alignment: .leading, spacing: 1) {
                    MarqueeText(text: session.title, font: .system(size: 13, weight: .semibold))
                    if !session.subtitle.isEmpty {
                        MarqueeText(text: session.subtitle, font: .system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    MediaButton(symbol: session.isPlaying ? "pause.fill" : "play.fill", size: 21,
                                label: session.isPlaying ? "Pause" : "Play") { model.nowPlaying.togglePlayPause(session) }
                    MediaButton(symbol: "forward.fill", size: 17, label: "Next Track") { model.nowPlaying.next(session) }
                }
                .foregroundStyle(session.isCurrent && session.isPlaying ? .primary : .secondary)
                .disabled(!session.isCurrent)
            }
            .frame(height: 65)
        }
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
                .frame(width: 26, height: 30)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Rounded-square artwork with the source app's icon as a badge on the corner.
struct Artwork: View {
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
            .frame(width: Metrics.artwork, height: Metrics.artwork)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            Image(nsImage: badge)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
                .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                .offset(x: 3, y: 3)
        }
        .accessibilityHidden(true)
    }
}

struct RowContextMenu: View {
    @Environment(AppModel.self) private var model
    let key: String
    let movable: Bool

    var body: some View {
        Toggle("Always Show", isOn: Binding(get: { model.store.state.pinned.contains(key) },
                                            set: { _ in model.togglePinned(key) }))
        Button("Reset Volume") { model.resetVolume(key) }
        Button("Hide") { Motion.animate { model.hide(key) } }
        if movable {
            Divider()
            Button("Move Up") { Motion.animate { model.moveApp(key, by: -1) } }
            Button("Move Down") { Motion.animate { model.moveApp(key, by: 1) } }
        }
    }
}

// MARK: Controls band

/// The lighter full-width band under an expanded row: Volume, Equalizer, Preset.
struct AppControls: View {
    @Environment(AppModel.self) private var model
    let key: String

    var body: some View {
        let s = model.settings(key)
        let volume = Binding(get: { model.settings(key).volume }, set: { model.setVolume(key, $0) })
        let eqOn = Binding(get: { model.settings(key).eqEnabled }, set: { model.setEQEnabled(key, $0) })
        let eqShown = Binding(get: { model.eqTarget == key }, set: { shown in
            if !shown, model.eqTarget == key { model.eqTarget = nil }
        })
        VStack(alignment: .leading, spacing: 0) {
            if model.permission.status == .denied { PermissionNotice().padding(.top, 10) }

            HStack(alignment: .firstTextBaseline) {
                Text("Volume").fontWeight(.semibold)
                Spacer()
                Text(s.volume.percent)
                    .monospacedDigit()
                    .foregroundStyle(s.volume > 1.0001 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            }
            .padding(.horizontal, Metrics.inset)
            .padding(.top, 13)

            SpeakerSlider(value: volume, range: 0...model.overdriveLimit, tint: Color(nsColor: .labelColor).opacity(0.85),
                          label: "\(model.displayName(key)) volume")
                .padding(.horizontal, Metrics.inset)
                .padding(.top, 8)
                .padding(.bottom, 11)

            InsetDivider(inset: 4)
            HStack {
                Text("Equalizer")
                Spacer()
                Toggle("Equalizer", isOn: eqOn).toggleStyle(.switch).labelsHidden()
            }
            .padding(.horizontal, Metrics.inset)
            .frame(height: 37)

            InsetDivider(inset: 4)
            HStack(spacing: 8) {
                Text("Preset")
                Button {
                    Motion.animate { model.eqTarget = model.eqTarget == key ? nil : key }
                } label: {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Equalizer")
                .accessibilityLabel("Show Equalizer")
                Spacer()
                PresetMenu(key: key)
            }
            .padding(.horizontal, Metrics.inset)
            .frame(height: 37)
            // Anchored to the full-width row so the arrow lands on the panel's left edge.
            .popover(isPresented: eqShown, arrowEdge: .leading) {
                EQPanel(key: key).environment(model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.07))
    }
}

struct PresetMenu: View {
    @Environment(AppModel.self) private var model
    let key: String
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        let current = model.settings(key).presetName
        Menu {
            ForEach(PresetStore.builtIn) { item($0, current: current) }
            if !model.presets.custom.isEmpty {
                Divider()
                ForEach(model.presets.custom) { item($0, current: current) }
            }
            Divider()
            Button("Save as Preset…", action: saveAsPreset)
        } label: {
            HStack(spacing: 8) {
                Text(current)
                    .contentTransition(.opacity)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.quaternary))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Preset")
        .accessibilityValue(current)
    }

    @ViewBuilder private func item(_ preset: EQPreset, current: String) -> some View {
        Toggle(preset.name, isOn: Binding(get: { preset.name == current }, set: { _ in
            Motion.animate { model.applyPreset(key, preset) }
        }))
    }

    private func saveAsPreset() {
        let alert = NSAlert()
        alert.messageText = "Save as Preset"
        alert.informativeText = "Enter a name for this equalizer setting."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
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

/// Single-line text that scrolls continuously when it doesn't fit, with the
/// next copy following 32pt behind. Static under Reduce Motion. Only rendered
/// while the panel is open, so the animation stops when it closes.
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
                    .animation(.linear(duration: Double((textWidth + gap) / speed)).delay(1).repeatForever(autoreverses: false),
                               value: scrolling)
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
