import AppKit

/// Attributed titles for native menu items. macOS 27 doesn't draw
/// `NSMenuItem.image`, but an image attached to the title still draws, so the
/// icon goes there and the item keeps its native highlight, keyboard handling
/// and submenu arrow.
@MainActor
enum MenuTitle {
    private static let font = NSFont.menuFont(ofSize: 0)
    private static let digits = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
    private static let iconGap: CGFloat = 7
    /// Right edge of the trailing value, measured from the title's origin. With
    /// AppKit's margins and submenu arrow this makes the item `Metrics.menuWidth` wide.
    private static let trailingEdge = Metrics.menuWidth - 74

    static func device(name: String, symbol: String, selected: Bool, trailing: String?) -> NSAttributedString {
        row(icon: circleIcon(symbol: symbol, selected: selected), size: 26, name: name, color: .labelColor, trailing: trailing)
    }

    static func app(name: String, icon: NSImage, trailing: String, dimmed: Bool) -> NSAttributedString {
        row(icon: icon, size: 18, name: name, color: dimmed ? .secondaryLabelColor : .labelColor, trailing: trailing)
    }

    private static func row(icon: NSImage, size: CGFloat, name: String, color: NSColor, trailing: String?) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = icon
        // Centred on the text's cap height, like an inline symbol.
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - size) / 2, width: size, height: size)
        let title = NSMutableAttributedString(attachment: attachment)
        // Kerning is ignored on an attachment, so the gap is a space stretched to `iconGap`.
        title.append(NSAttributedString(string: " ", attributes: [.font: font, .kern: iconGap - width(of: " ", font: font)]))

        var room = trailingEdge - size - iconGap
        if let trailing { room -= width(of: trailing, font: digits) + 12 }
        title.append(NSAttributedString(string: truncated(name, to: room), attributes: [.font: font, .foregroundColor: color]))
        if let trailing {
            title.append(NSAttributedString(string: "\t" + trailing,
                                            attributes: [.font: digits, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: trailingEdge)]
        title.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: title.length))
        return title
    }

    private static func width(of text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// Menus never truncate attributed titles, so a long name is cut here.
    private static func truncated(_ text: String, to room: CGFloat) -> String {
        guard width(of: text, font: font) > room else { return text }
        var head = Substring(text)
        while !head.isEmpty, width(of: head + "…", font: font) > room { head = head.dropLast() }
        return head.trimmingCharacters(in: .whitespaces) + "…"
    }

    private static var circles: [String: NSImage] = [:]

    /// The system Sound menu's device icon: an accent circle when selected, grey otherwise.
    /// The drawing handler runs per appearance, so it follows light and dark mode.
    private static func circleIcon(symbol: String, selected: Bool) -> NSImage {
        let key = "\(symbol)|\(selected)"
        if let cached = circles[key] { return cached }
        let image = NSImage(size: NSSize(width: 26, height: 26), flipped: false) { rect in
            (selected ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.1)).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                .applying(.init(paletteColors: [selected ? .white : NSColor.labelColor.withAlphaComponent(0.75)]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let size = glyph.size
                glyph.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                      width: size.width, height: size.height))
            }
            return true
        }
        circles[key] = image
        return image
    }
}
