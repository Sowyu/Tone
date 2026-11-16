import AppKit
import SwiftUI

// MARK: Hosting

/// Whether AppKit currently highlights the menu item that hosts a row.
@MainActor @Observable
final class RowState {
    var highlighted = false
}

/// Hosts a SwiftUI row inside an NSMenuItem. AppKit tracks hover and keyboard
/// selection for view items and redraws the view when that changes; `draw`
/// forwards the item's `isHighlighted` to SwiftUI, which paints the native
/// highlight (accent fill, white text).
final class MenuHostView: NSView {
    let state: RowState
    private let hosting: NSHostingView<AnyView>

    init<Content: View>(@ViewBuilder _ content: (RowState) -> Content) {
        let state = RowState()
        self.state = state
        hosting = NSHostingView(rootView: AnyView(content(state).frame(width: Metrics.menuWidth)))
        hosting.sizingOptions = [.intrinsicContentSize]
        let size = hosting.fittingSize
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.menuWidth, height: size.height))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = enclosingMenuItem?.isHighlighted ?? false
        if state.highlighted != highlighted { state.highlighted = highlighted }
    }

    /// Runs the hosting item's action and closes the menu, like a native item click.
    func activate() {
        guard let item = enclosingMenuItem else { return }
        item.menu?.cancelTracking()
        if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
    }
}

/// The native highlight, measured from macOS 27 menus.
private struct NativeHighlight: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .background {
                if on {
                    RoundedRectangle(cornerRadius: Metrics.highlightRadius, style: .continuous)
                        .fill(Color(nsColor: .controlAccentColor))
                        .padding(.horizontal, Metrics.highlightInset)
                }
            }
    }
}

extension View {
    func nativeHighlight(_ on: Bool) -> some View { modifier(NativeHighlight(on: on)) }

    /// Secondary text that turns white on highlight, as native items do.
    func secondaryText(_ highlighted: Bool) -> some View {
        foregroundStyle(highlighted ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(.secondary))
    }
}

/// Small chevron drawn where AppKit would draw a submenu arrow.
struct SubmenuChevron: View {
    let highlighted: Bool
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .secondaryText(highlighted)
    }
}

// MARK: Header and master volume

struct HeaderRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Sound").font(.system(size: 13, weight: .bold))
            Spacer()
            Text(Double(model.devices.masterVolume).percent)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .padding(.horizontal, Metrics.inset)
        .padding(.top, 2)
        .frame(height: Metrics.rowHeight)
    }
}

struct MasterSliderRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let devices = model.devices
        SpeakerSlider(value: Binding(get: { Double(devices.masterVolume) }, set: { devices.setMasterVolume(Float($0)) }),
                      label: "Output volume")
            .disabled(!devices.canSetVolume)
            .padding(.horizontal, Metrics.inset)
            .padding(.vertical, 4)
    }
}

// MARK: Devices

/// Same layout as the device rows in the system Sound menu.
struct DeviceRowView: View {
    let state: RowState
    let name: String
    let symbol: String
    let isSelected: Bool
    var battery: BatteryLevel?
    var isConnecting = false
    var expandable = false
    var expanded = false
    var onToggleExpand: () -> Void = {}
    let activate: () -> Void

    var body: some View {
        let on = state.highlighted
        Button(action: activate) {
            HStack(spacing: 9) {
                ZStack {
                    Circle().fill(isSelected ? AnyShapeStyle(Color.accentColor)
                                             : AnyShapeStyle(on ? Color.white.opacity(0.25) : Color.primary.opacity(0.1)))
                    if isConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isSelected || on ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary.opacity(0.75)))
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
                        .secondaryText(on)
                    }
                }
                Spacer(minLength: 4)
                if battery?.buds == nil, let main = battery?.main {
                    Text("\(main)%").secondaryText(on)
                    Image(systemName: Self.batterySymbol(main)).secondaryText(on)
                }
                if expandable {
                    Button(action: onToggleExpand) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .secondaryText(on)
                            .frame(width: 22, height: Metrics.deviceRowHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Hide listening modes" : "Show listening modes")
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, Metrics.inset)
            .frame(height: Metrics.deviceRowHeight)
            .contentShape(Rectangle())
            .nativeHighlight(on)
        }
        .buttonStyle(.plain)
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
}

/// "Listening Mode" choices under an expanded AirPods row: checkmark column, glyph, title.
struct ModeRowView: View {
    let state: RowState
    let mode: ListeningMode
    let isSelected: Bool
    let activate: () -> Void

    var body: some View {
        let on = state.highlighted
        Button(action: activate) {
            HStack(spacing: 0) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 22, alignment: .leading)
                ModeGlyph(mode: mode)
                    .secondaryText(on)
                    .frame(width: 28, alignment: .leading)
                Text(mode.title)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .padding(.leading, Metrics.inset)
            .frame(height: Metrics.rowHeight)
            .contentShape(Rectangle())
            .nativeHighlight(on)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                        Image(systemName: "sparkle").font(.system(size: 7, weight: .bold)).offset(x: 5, y: -3)
                    }
            }
        }
        .font(.system(size: 14))
    }
}

// MARK: Now Playing and apps

struct SessionRowView: View {
    @Environment(AppModel.self) private var model
    let state: RowState
    /// Source app bundle ID. The row reads the session live from the model so
    /// play/pause, title and artwork update while the menu is open.
    let id: String

    var body: some View {
        if let session = model.nowPlaying.sessions.first(where: { $0.id == id }) {
            row(session)
        }
    }

    private func row(_ session: NowPlayingSession) -> some View {
        let on = state.highlighted
        return HStack(spacing: 10) {
            Artwork(image: session.artwork, badge: model.icon(session.id))
            VStack(alignment: .leading, spacing: 1) {
                MarqueeText(text: session.title, font: .system(size: 13, weight: .semibold), animated: model.isMenuOpen)
                if !session.subtitle.isEmpty {
                    MarqueeText(text: session.subtitle, font: .system(size: 12), animated: model.isMenuOpen)
                        .secondaryText(on)
                }
            }
            HStack(spacing: 6) {
                MediaButton(symbol: session.isPlaying ? "pause.fill" : "play.fill", size: 17,
                            label: session.isPlaying ? "Pause" : "Play") { model.nowPlaying.togglePlayPause(session) }
                MediaButton(symbol: "forward.fill", size: 14, label: "Next Track") { model.nowPlaying.next(session) }
            }
            .disabled(!session.isCurrent)
            .opacity(session.isCurrent ? 1 : 0.4)
            SubmenuChevron(highlighted: on)
        }
        .font(.system(size: 13))
        .padding(.horizontal, Metrics.inset)
        .frame(height: 50)
        .nativeHighlight(on)
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
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct AppRowView: View {
    @Environment(AppModel.self) private var model
    let state: RowState
    let initial: AppRowItem

    /// Read live so running state and name update while the menu is open.
    private var item: AppRowItem { model.applicationRows.first { $0.id == initial.id } ?? initial }

    var body: some View {
        let item = self.item
        let on = state.highlighted
        let volume = model.settings(item.id).volume
        HStack(spacing: 8) {
            Image(nsImage: model.icon(item.id))
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
                .opacity(item.isRunning ? 1 : 0.5)
            Text(item.name).lineLimit(1)
            Spacer(minLength: 4)
            if model.settings(item.id).eqEnabled {
                Image(systemName: "slider.vertical.3").font(.system(size: 11)).secondaryText(on)
            }
            Text(volume.percent)
                .monospacedDigit()
                .foregroundStyle(volume > 1.0001 && !on ? AnyShapeStyle(Color.orange) : AnyShapeStyle(on ? Color.white.opacity(0.8) : Color.secondary))
            SubmenuChevron(highlighted: on)
        }
        .font(.system(size: 13))
        .padding(.horizontal, Metrics.inset)
        .frame(height: Metrics.rowHeight)
        .nativeHighlight(on)
    }
}

/// First item of an app's submenu: "Volume" with its percentage and a slider.
struct AppVolumeRow: View {
    @Environment(AppModel.self) private var model
    let key: String

    var body: some View {
        let volume = model.settings(key).volume
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Volume").fontWeight(.semibold)
                Spacer()
                Text(volume.percent)
                    .monospacedDigit()
                    .foregroundStyle(volume > 1.0001 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            }
            SpeakerSlider(value: Binding(get: { model.settings(key).volume }, set: { model.setVolume(key, $0) }),
                          range: 0...model.overdriveLimit, tint: Color(nsColor: .labelColor).opacity(0.85),
                          label: "\(model.displayName(key)) volume")
        }
        .font(.system(size: 13))
        .padding(.horizontal, Metrics.inset)
        .padding(.vertical, 6)
    }
}

// MARK: Artwork and marquee
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
            .frame(width: 34, height: 34)
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
struct MarqueeText: View {
    let text: String
    let font: Font
    var animated = true
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var scrolling = false
    private let gap: CGFloat = 32
    private let speed: CGFloat = 30

    private var overflows: Bool { textWidth > boxWidth + 1 && !Motion.reduce && animated }

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
