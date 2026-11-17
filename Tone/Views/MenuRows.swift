import AppKit
import SwiftUI

extension NSMenuItem {
    /// An item that hosts a SwiftUI row. Only for rows that hold a control:
    /// view items can't open submenus and don't get the native highlight.
    @MainActor
    static func hosting(_ row: some View) -> NSMenuItem {
        let view = NSHostingView(rootView: row.frame(minWidth: Metrics.menuWidth, idealWidth: Metrics.menuWidth, maxWidth: .infinity))
        view.frame.size = view.fittingSize
        view.autoresizingMask = .width
        let item = NSMenuItem()
        item.view = view
        return item
    }
}

// MARK: Volume

/// A bold title with the level beside it, above a slider between two speaker glyphs.
struct VolumeRow: View {
    let title: String
    let accessibilityLabel: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var isEnabled: () -> Bool = { true }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).fontWeight(.semibold)
                Spacer()
                Text(value.percent).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                Slider(value: $value, in: range) { Text(accessibilityLabel) }
                    .labelsHidden()
                    .disabled(!isEnabled())
                Image(systemName: "speaker.wave.3.fill")
            }
            .foregroundStyle(.secondary)
        }
        .font(.system(size: NSFont.systemFontSize))
        .padding(.horizontal, Metrics.inset)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

/// First item of an app's submenu.
struct AppVolumeRow: View {
    @Environment(AppModel.self) private var model
    let key: String

    var body: some View {
        VolumeRow(title: "Volume", accessibilityLabel: "\(model.displayName(key)) Volume",
                  value: Binding(get: { model.settings(key).volume }, set: { model.setVolume(key, $0) }),
                  range: 0...model.overdriveLimit)
    }
}

// MARK: Now Playing

/// Reads its session live from the model, so the title, artwork and play state
/// update while the menu is open.
struct NowPlayingRow: View {
    @Environment(AppModel.self) private var model
    /// Source app bundle ID.
    let id: String

    var body: some View {
        if let session = model.nowPlaying.sessions.first(where: { $0.id == id }) {
            HStack(spacing: 10) {
                Artwork(image: session.artwork, badge: model.icon(session.id))
                VStack(alignment: .leading, spacing: 1) {
                    MarqueeText(text: session.title, font: .system(size: NSFont.systemFontSize, weight: .medium),
                                isActive: model.isMenuOpen)
                    if !session.subtitle.isEmpty {
                        MarqueeText(text: session.subtitle, font: .system(size: NSFont.smallSystemFontSize),
                                    isActive: model.isMenuOpen)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 2) {
                    MediaButton(symbol: session.isPlaying ? "pause.fill" : "play.fill", size: 16,
                                label: session.isPlaying ? "Pause" : "Play") { model.nowPlaying.togglePlayPause(session) }
                    MediaButton(symbol: "forward.fill", size: 13, label: "Next Track") { model.nowPlaying.next(session) }
                }
                .disabled(!session.isCurrent)
            }
            .padding(.leading, Metrics.inset)
            .padding(.trailing, Metrics.inset - 5)
            .frame(height: 46)
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
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Image(nsImage: badge)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
                .offset(x: 4, y: 4)
        }
        .accessibilityHidden(true)
    }
}

/// One line of text that scrolls when it doesn't fit.
private struct MarqueeText: View {
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
