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
