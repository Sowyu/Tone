import AppKit

/// Attributed titles for native NSMenuItems. macOS 27 hides `NSMenuItem.image`,
/// but images inside an attributed title still draw, so the icon goes there and
/// AppKit keeps native highlight, clicks, keyboard and submenu arrows.
@MainActor
enum MenuTitle {
    private static let font = NSFont.menuFont(ofSize: 13)
    /// Right edge for trailing values (battery, volume), before the submenu arrow.
    private static let trailingTab: CGFloat = 250

    static func device(name: String, symbol: String, selected: Bool, trailing: String?) -> NSAttributedString {
        let title = NSMutableAttributedString()
        title.append(attachment(circleIcon(symbol: symbol, selected: selected), size: 26))
        title.append(NSAttributedString(string: "  " + name, attributes: [.font: font]))
        if let trailing { title.append(trailingText(trailing, color: .secondaryLabelColor)) }
        title.addAttribute(.paragraphStyle, value: paragraph(), range: NSRange(location: 0, length: title.length))
        return title
    }

    static func app(name: String, icon: NSImage, percent: String, overdrive: Bool, dimmed: Bool) -> NSAttributedString {
        let title = NSMutableAttributedString()
        title.append(attachment(icon, size: 18))
        title.append(NSAttributedString(string: "  " + name, attributes: [
            .font: font, .foregroundColor: dimmed ? NSColor.tertiaryLabelColor : NSColor.labelColor,
        ]))
        title.append(trailingText(percent, color: overdrive ? .systemOrange : .secondaryLabelColor))
        title.addAttribute(.paragraphStyle, value: paragraph(), range: NSRange(location: 0, length: title.length))
        return title
    }

    static func symbol(_ image: NSImage, title: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(attachment(image, size: 18))
        result.append(NSAttributedString(string: "  " + title, attributes: [.font: font]))
        return result
    }

    // MARK: Pieces

    private static func paragraph() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: trailingTab)]
        return style
    }

    private static func trailingText(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: "\t" + text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular), .foregroundColor: color,
        ])
    }

    /// Vertically centred on the text like an inline icon.
    private static func attachment(_ image: NSImage, size: CGFloat) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - size) / 2, width: size, height: size)
        return NSAttributedString(attachment: attachment)
    }

    private static var circles: [String: NSImage] = [:]

    /// The system Sound menu's device icon: accent circle when selected, grey otherwise.
    /// Drawn per appearance, so it follows light and dark mode and the accent colour.
    static func circleIcon(symbol: String, selected: Bool) -> NSImage {
        let key = "\(symbol)|\(selected)"
        if let cached = circles[key] { return cached }
        let image = NSImage(size: NSSize(width: 26, height: 26), flipped: false) { rect in
            (selected ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.1)).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                .applying(.init(paletteColors: [selected ? .white : NSColor.labelColor.withAlphaComponent(0.75)]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = glyph.size
                glyph.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
        circles[key] = image
        return image
    }

    /// Listening mode glyphs. Adaptive has no SF Symbol, so it's a person with a sparkle.
    static func modeIcon(_ mode: ListeningMode) -> NSImage {
        let name: String = switch mode {
        case .off: "person.fill"
        case .transparency: "person.and.background.dotted"
        case .noiseCancellation: "person.bust.circle.fill"
        case .adaptive: "person.fill"
        }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let base = NSImage(systemSymbolName: name, accessibilityDescription: mode.title)?.withSymbolConfiguration(config) ?? NSImage()
        guard mode == .adaptive else {
            base.isTemplate = true
            return base
        }
        let sparkle = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .bold))
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let s = base.size
            base.draw(in: NSRect(x: rect.midX - s.width / 2 - 1, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            if let sparkle {
                sparkle.draw(in: NSRect(x: rect.maxX - sparkle.size.width, y: rect.maxY - sparkle.size.height,
                                        width: sparkle.size.width, height: sparkle.size.height))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
