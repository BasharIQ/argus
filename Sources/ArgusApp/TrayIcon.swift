import AppKit

/// The bundled Argus logo, shared by the menu bar icon and the menu UI.
enum AppLogo {
    static let image: NSImage = {
        guard let url = Bundle.module.url(forResource: "logo", withExtension: "png"),
              let logo = NSImage(contentsOf: url) else {
            // Unreachable in a built bundle; keeps the icon usable if resources go missing.
            return NSImage(systemSymbolName: "eyes", accessibilityDescription: nil)!
        }
        return logo
    }()
}

/// Menu bar icon: the Argus logo on an ink pill, with the count of waiting
/// sessions in coral when anything needs input (1a "Inbox" handoff). Rendered
/// non-template because the coral count can't follow the menu bar tint.
enum TrayIcon {
    private static let pillHeight: CGFloat = 22
    private static let pillInset: CGFloat = 7
    private static let logoSide: CGFloat = 14
    private static let countGap: CGFloat = 6

    private static let ink = NSColor(srgbRed: 26 / 255, green: 26 / 255, blue: 25 / 255, alpha: 1)
    private static let paper = NSColor(srgbRed: 244 / 255, green: 244 / 255, blue: 242 / 255, alpha: 1)
    private static let coral = NSColor(srgbRed: 255 / 255, green: 90 / 255, blue: 72 / 255, alpha: 1)

    /// One image instance per count. Rebuilding the image on every scan made
    /// the status item relayout (and the menu bar items next to it slide).
    private static var cache: [Int: NSImage] = [:]

    static func image(waitingCount: Int) -> NSImage {
        if let cached = cache[waitingCount] { return cached }
        let image = render(waitingCount: waitingCount)
        cache[waitingCount] = image
        return image
    }

    private static func render(waitingCount: Int) -> NSImage {
        var count: NSAttributedString?
        var width = pillInset * 2 + logoSide
        if waitingCount > 0 {
            count = attributedCount("\(waitingCount)")
            width += countGap + count!.size().width
        }

        return rendered(in: NSSize(width: ceil(width), height: pillHeight)) { rect in
            ink.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            let logo = tinted(paper, AppLogo.image)
            logo.draw(
                in: NSRect(x: pillInset, y: (pillHeight - logoSide) / 2, width: logoSide, height: logoSide))
            if let count {
                let size = count.size()
                count.draw(at: NSPoint(x: pillInset + logoSide + countGap, y: (pillHeight - size.height) / 2))
            }
        }
    }

    private static func attributedCount(_ text: String) -> NSAttributedString {
        // Space Mono, bundled and registered at launch; system mono fallback
        // keeps the count readable if registration ever fails.
        let font = NSFont(name: "SpaceMono-Regular", size: 12)
            ?? NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: coral,
        ])
    }

    private static func tinted(_ tint: NSColor, _ image: NSImage) -> NSImage {
        let rect = NSRect(origin: .zero, size: image.size)
        let result = NSImage(size: image.size)
        result.lockFocus()
        image.draw(in: rect)
        tint.set()
        rect.fill(using: .sourceAtop)
        result.unlockFocus()
        return result
    }

    /// Draws into a 2x bitmap so the icon stays crisp on retina menu bars.
    private static func rendered(in size: NSSize, _ drawing: (NSRect) -> Void) -> NSImage {
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawing(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }
}
