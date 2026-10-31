import CoreGraphics
import CoreText
import Foundation

/// How MonetShot draws the pointer.
public enum CursorStyle: String, Codable, CaseIterable, Sendable {
    /// The Mac's own: black arrow, white rim.
    case classic
    /// Inverted: white arrow, dark rim.
    case white
    /// A rounded, chunky arrow in a soft colour.
    case soft
    /// A translucent dot, as touch demos show a finger.
    case dot
    /// A soft arrow with a name tag, as in a multiplayer design tool.
    case tag

    public var label: String {
        switch self {
        case .classic: "Classic"
        case .white: "White"
        case .soft: "Soft"
        case .dot: "Dot"
        case .tag: "Name tag"
        }
    }

    /// Styles that take a colour.
    public var tinted: Bool { self == .soft || self == .dot || self == .tag }
}

/// The soft colours a cursor can wear.
public enum CursorTint: String, Codable, CaseIterable, Sendable {
    case clay, sky, mint, butter, lilac, rose

    /// sRGB hex.
    public var hex: UInt32 {
        switch self {
        case .clay: 0xE07A55
        case .sky: 0x5F9FD8
        case .mint: 0x4FB38E
        case .butter: 0xE8B53E
        case .lilac: 0x9584DB
        case .rose: 0xE07C9E
        }
    }

    var cg: CGColor { CursorArt.color(hex) }
}

/// The cursor MonetShot draws over the recording, as vectors so it stays crisp at
/// any zoom. Pure CoreGraphics and CoreText: one geometry, every size.
public enum CursorArt {
    /// Height of the arrow in screen points at 1x (the real one is about this).
    public static let pointHeight: Double = 22
    /// The arrow on a 22-unit grid, tip at (0,0), y pointing down.
    static let outline: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 18.2), CGPoint(x: 4.3, y: 14.1),
        CGPoint(x: 7.4, y: 21.0), CGPoint(x: 10.6, y: 19.6), CGPoint(x: 7.6, y: 12.8),
        CGPoint(x: 13.4, y: 12.8),
    ]
    /// A plumper arrow for the soft styles: shorter tail, wider wings.
    static let softOutline: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16.4), CGPoint(x: 4.6, y: 12.6),
        CGPoint(x: 7.2, y: 18.4), CGPoint(x: 10.4, y: 17.0), CGPoint(x: 7.9, y: 11.4),
        CGPoint(x: 13.6, y: 11.4),
    ]
    static let gridHeight: CGFloat = 22

    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let ink = CGColor(srgbRed: 0.06, green: 0.06, blue: 0.07, alpha: 1)

    /// The classic arrow, kept for callers that don't pick a style.
    public static func image(pixelHeight: Int) -> (image: CGImage, tip: CGPoint)? {
        image(style: .classic, tint: .clay, label: "", pixelHeight: pixelHeight)
    }

    /// Renders the cursor so its arrow is `pixelHeight` tall (plus room for
    /// rim, shadow and any tag). Returns the image and where the hotspot sits
    /// in it (the tip, or the dot's centre), from the top-left corner in pixels.
    public static func image(style: CursorStyle, tint: CursorTint, label: String, pixelHeight: Int) -> (image: CGImage, tip: CGPoint)? {
        let s = CGFloat(pixelHeight) / gridHeight
        let margin = ceil(4 * s)
        let tagText = label.isEmpty ? "You" : String(label.prefix(18))
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, 7.4 * s, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, 7.4 * s, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: tagText, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
        ]))
        let textW = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let pill = CGRect(x: 11.5 * s, y: 15.5 * s, width: textW + 9 * s, height: 12 * s)

        let contentW: CGFloat, contentH: CGFloat
        switch style {
        case .dot: contentW = 22 * s; contentH = 22 * s
        case .tag: contentW = pill.maxX + 1 * s; contentH = pill.maxY + 1 * s
        default: contentW = 14 * s; contentH = 22 * s
        }
        let w = Int(ceil(contentW + margin * 2)), h = Int(ceil(contentH + margin * 2))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Draw with a top-left origin to match the grid.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: margin, y: margin)
        ctx.setShouldAntialias(true)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        let shadow = color(0x000000, alpha: 0.32)

        func arrow(_ pts: [CGPoint]) -> CGPath {
            let p = CGMutablePath()
            p.addLines(between: pts.map { CGPoint(x: $0.x * s, y: $0.y * s) })
            p.closeSubpath()
            return p
        }

        switch style {
        case .classic, .white:
            let path = arrow(outline)
            let body = style == .classic ? ink : white
            let rim = style == .classic ? white : ink
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -0.8 * s), blur: 2.2 * s, color: shadow)
            ctx.addPath(path); ctx.setFillColor(rim); ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(path); ctx.setStrokeColor(rim); ctx.setLineWidth((style == .classic ? 2.4 : 1.8) * s); ctx.strokePath()
            ctx.addPath(path); ctx.setFillColor(body); ctx.fillPath()

        case .soft, .tag:
            let path = arrow(softOutline)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1 * s), blur: 2.6 * s, color: shadow)
            ctx.addPath(path); ctx.setStrokeColor(white); ctx.setLineWidth(4.4 * s); ctx.strokePath()
            ctx.restoreGState()
            // A thick round stroke in the body colour rounds every corner.
            ctx.addPath(path); ctx.setStrokeColor(tint.cg); ctx.setLineWidth(1.6 * s); ctx.strokePath()
            ctx.addPath(path); ctx.setFillColor(tint.cg); ctx.fillPath()
            if style == .tag {
                let r = pill.height / 2
                let pillPath = CGPath(roundedRect: pill, cornerWidth: r, cornerHeight: r, transform: nil)
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -1 * s), blur: 2.6 * s, color: shadow)
                ctx.addPath(pillPath); ctx.setFillColor(white); ctx.fillPath()
                ctx.restoreGState()
                ctx.addPath(CGPath(roundedRect: pill.insetBy(dx: 0.9 * s, dy: 0.9 * s), cornerWidth: r - 0.9 * s,
                                   cornerHeight: r - 0.9 * s, transform: nil))
                ctx.setFillColor(tint.cg); ctx.fillPath()
                // CoreText draws y-up: flip locally around the baseline.
                ctx.saveGState()
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                ctx.textPosition = CGPoint(x: pill.minX + 4.5 * s, y: pill.midY + 2.6 * s)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }

        case .dot:
            let disc = CGRect(x: 2 * s, y: 2 * s, width: 18 * s, height: 18 * s)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -0.8 * s), blur: 3 * s, color: color(0x000000, alpha: 0.22))
            ctx.addEllipse(in: disc); ctx.setFillColor(color(tint.hex, alpha: 0.42)); ctx.fillPath()
            ctx.restoreGState()
            ctx.addEllipse(in: disc.insetBy(dx: 0.9 * s, dy: 0.9 * s))
            ctx.setStrokeColor(color(0xFFFFFF, alpha: 0.95)); ctx.setLineWidth(1.8 * s); ctx.strokePath()
            ctx.addEllipse(in: disc.insetBy(dx: 6.4 * s, dy: 6.4 * s))
            ctx.setFillColor(color(tint.hex, alpha: 0.9)); ctx.fillPath()
        }

        guard let img = ctx.makeImage() else { return nil }
        let hotspot = style == .dot ? CGPoint(x: margin + 11 * s, y: margin + 11 * s) : CGPoint(x: margin, y: margin)
        return (img, hotspot)
    }
}
