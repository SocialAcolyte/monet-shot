import CoreGraphics
import CoreText
import Foundation

/// Text overlays drawn as pictures, in Inter Bold (`Resources/Fonts`, the
/// file the desktop apps draw with). Laid out glyph by glyph with fixed em
/// metrics (`TextMotion`), no shaping or kerning, so every app puts each
/// letter in the same place.
public enum TextArt {
    public struct Image {
        public let image: CGImage
        /// Its size in canvas pixels (the image is that size, not scaled).
        public let width: Int
        public let height: Int
    }

    static let fontURL: URL? = {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Fonts/Inter-Bold.ttf")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Fonts/Inter-Bold.ttf")
        return [bundled, repo].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }()

    // Immutable once made; CoreText descriptors are safe to share.
    nonisolated(unsafe) static let descriptor: CTFontDescriptor? = {
        guard let fontURL, let data = try? Data(contentsOf: fontURL) else { return nil }
        return CTFontManagerCreateFontDescriptorFromData(data as CFData)
    }()

    static func font(_ px: Double) -> CTFont {
        if let descriptor { return CTFontCreateWithFontDescriptor(descriptor, px, nil) }
        return CTFontCreateUIFontForLanguage(.emphasizedSystem, px, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, px, nil)
    }

    /// Glyphs and their pen positions for one line, and its width.
    static func layout(_ line: String, font: CTFont, tracking: Double) -> (glyphs: [CGGlyph], xs: [CGFloat], chars: [Character], width: CGFloat) {
        var glyphs: [CGGlyph] = [], xs: [CGFloat] = [], chars: [Character] = []
        var x: CGFloat = 0
        let track = CGFloat(tracking) * CTFontGetSize(font)
        for (k, ch) in line.enumerated() {
            let units = Array(String(ch).utf16)
            var g = [CGGlyph](repeating: 0, count: units.count)
            CTFontGetGlyphsForCharacters(font, units, &g, units.count)
            var adv = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, [g[0]], &adv, 1)
            if k > 0 { x += track }
            glyphs.append(g[0]); xs.append(x); chars.append(ch)
            x += adv.width
        }
        return (glyphs, xs, chars, x)
    }

    // The same picture serves every frame of a text but while its words arrive.
    nonisolated(unsafe) private static var cache: [String: Image] = [:]
    private static let lock = NSLock()

    /// The picture of `state` with its tone and backing; nil if there is nothing to draw.
    public static func image(_ state: TextState, tone: TextTone, backing: Bool) -> Image? {
        let key = "\(state.lines)|\(state.px)|\(state.tracking)|\(state.words.map { Int(($0 * 255).rounded()) })|\(tone.rawValue)|\(backing)"
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let made = draw(state, tone: tone, backing: backing)
        lock.lock()
        if cache.count > 48 { cache.removeAll() }
        cache[key] = made
        lock.unlock()
        return made
    }

    static func draw(_ state: TextState, tone: TextTone, backing: Bool) -> Image? {
        let px = state.px
        guard px >= 2 else { return nil }
        let font = font(px)
        let lines = state.lines.map { layout($0, font: font, tracking: state.tracking) }
        let blockW = lines.map(\.width).max() ?? 0
        let lh = TextMotion.lineHeight * px
        let padX = TextMotion.padX * px, padY = TextMotion.padY * px
        let w = Int((Double(blockW) + 2 * padX).rounded(.up)), h = Int((Double(lines.count) * lh + 2 * padY).rounded(.up))
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Plain coverage, no font smoothing (dilation), as the other apps rasterise.
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldSmoothFonts(false)
        // Draw top-down, as the other apps do.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        func color(_ hex: UInt32, _ a: Double) -> CGColor {
            CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: CGFloat(a))
        }
        if backing {
            let r = TextMotion.radius * px
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.setFillColor(color(tone.backingHex, tone.backingAlpha))
            ctx.fillPath()
        }
        let shadowed = TextMotion.hasShadow(tone: tone, backing: backing)
        if shadowed {
            // CoreGraphics shadow offsets are y-up whatever the transform; its blur is ~2 sigma.
            // One layer, so the words cast one shadow (not each glyph over its neighbour).
            ctx.setShadow(offset: CGSize(width: 0, height: -TextMotion.shadowOffset * px), blur: 2 * TextMotion.shadowSigma * px,
                          color: CGColor(srgbRed: 0.04, green: 0.035, blue: 0.03, alpha: TextMotion.shadowAlpha))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        var word = -1
        var inWord = false
        for (i, l) in lines.enumerated() {
            let x0 = (CGFloat(w) - l.width) / 2
            let baseline = padY + Double(i) * lh + TextMotion.baseline * px
            inWord = false
            for k in l.glyphs.indices {
                let space = l.chars[k] == " " || l.chars[k] == "\t"
                if !space && !inWord { word += 1 }
                inWord = !space
                if space { continue }
                let alpha = state.words.isEmpty ? 1 : (state.words.indices.contains(word) ? state.words[word] : 0)
                guard alpha > 0.001 else { continue }
                ctx.saveGState()
                // Glyphs draw y-up: flip back about the baseline.
                ctx.translateBy(x: x0 + l.xs[k], y: CGFloat(baseline))
                ctx.scaleBy(x: 1, y: -1)
                ctx.setFillColor(color(tone.hex, alpha))
                var g = l.glyphs[k]
                var at = CGPoint.zero
                CTFontDrawGlyphs(font, &g, &at, 1, ctx)
                ctx.restoreGState()
            }
        }
        if shadowed { ctx.endTransparencyLayer() }
        guard let img = ctx.makeImage() else { return nil }
        return Image(image: img, width: w, height: h)
    }
}
