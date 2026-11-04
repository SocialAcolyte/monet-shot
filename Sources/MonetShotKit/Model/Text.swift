import Foundation

/// Words on the video: a title, a caption, a label. Times are output time
/// (like camera clips recorded over the edit), so a text stays where it was
/// put on the finished video's clock; positions are on the canvas, so it
/// doesn't zoom with the recording.
public struct TextOverlay: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var at: Double
    public var duration: Double
    public var style: TextStyle = .title
    public var animation: TextAnimation = .rise
    /// The centre of the text block, 0...1 across and down the canvas.
    public var x: Double = 0.5
    public var y: Double = 0.5
    /// Size relative to the style's own.
    public var size: Double = 1
    public var tone: TextTone = .light
    /// A soft box behind the words (nil = the style's choice).
    public var backing: Bool?
    public var uppercase = false

    public init(id: UUID = UUID(), text: String, at: Double, duration: Double = 3, style: TextStyle = .title,
                animation: TextAnimation = .rise) {
        self.id = id
        self.text = text
        self.at = at
        self.duration = duration
        self.style = style
        self.animation = animation
        (x, y) = style.place
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        at = try c.decode(Double.self, forKey: .at)
        duration = try c.decode(Double.self, forKey: .duration)
        style = try c.decodeIfPresent(TextStyle.self, forKey: .style) ?? .title
        animation = try c.decodeIfPresent(TextAnimation.self, forKey: .animation) ?? .rise
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.5
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 1
        tone = try c.decodeIfPresent(TextTone.self, forKey: .tone) ?? .light
        backing = try c.decodeIfPresent(Bool.self, forKey: .backing)
        uppercase = try c.decodeIfPresent(Bool.self, forKey: .uppercase) ?? false
    }

    public var end: Double { at + duration }
    public func covers(_ t: Double) -> Bool { t >= at && t < end }
    public var hasBacking: Bool { backing ?? style.backed }
}

public enum TextStyle: String, Codable, CaseIterable, Sendable {
    /// Big words, for the start of a video or a new section.
    case title
    /// A line along the bottom, on a dark box.
    case caption
    /// A small tag on a pale pill, to point at something.
    case label

    public var label: String {
        switch self {
        case .title: "Title"
        case .caption: "Caption"
        case .label: "Label"
        }
    }
    /// Font size as a fraction of the canvas's shorter side.
    public var em: Double {
        switch self {
        case .title: 0.085
        case .caption: 0.042
        case .label: 0.036
        }
    }
    /// Extra space between letters, in ems.
    public var tracking: Double {
        switch self {
        case .title: -0.01
        case .caption: 0
        case .label: 0.02
        }
    }
    public var backed: Bool { self != .title }
    /// Where a new one goes.
    public var place: (Double, Double) {
        switch self {
        case .title: (0.5, 0.45)
        case .caption: (0.5, 0.86)
        case .label: (0.5, 0.2)
        }
    }
}

public enum TextAnimation: String, Codable, CaseIterable, Sendable {
    /// Fades in and out.
    case fade
    /// Fades in while drifting up into place.
    case rise
    /// Springs in from a little smaller, with a touch of overshoot.
    case pop
    /// One word after another.
    case words

    public var label: String {
        switch self {
        case .fade: "Fade"
        case .rise: "Rise"
        case .pop: "Pop"
        case .words: "Word by word"
        }
    }
}

public enum TextTone: String, Codable, CaseIterable, Sendable {
    case light, dark, clay

    public var label: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .clay: "Clay"
        }
    }
    /// The words' colour (sRGB).
    public var hex: UInt32 {
        switch self {
        case .light: 0xF7F4EE
        case .dark: 0x17191B
        case .clay: 0xE07A55
        }
    }
    /// The box behind them, and its opacity.
    public var backingHex: UInt32 { self == .dark ? 0xF3F0E8 : 0x17191B }
    public var backingAlpha: Double { self == .dark ? 0.92 : 0.72 }
}

/// How a text looks at one moment: the shared answer both apps draw from.
public struct TextState: Equatable, Sendable {
    /// The lines as drawn (upper-cased if asked).
    public var lines: [String]
    /// Font size in canvas pixels.
    public var px: Double
    public var tracking: Double
    /// Centre of the block on the canvas (pixels, top-left origin), with the rise applied.
    public var centerX: Double
    public var centerY: Double
    public var opacity: Double
    public var scale: Double
    /// One per word, in reading order; empty unless the words come one by one.
    public var words: [Double]
}

public enum TextMotion {
    /// Line box height and where the baseline sits in it, in ems. Fixed
    /// (not the font's own metrics) so every app lays the lines out alike.
    public static let lineHeight = 1.22
    public static let baseline = 0.94
    /// Padding of the backing box, in ems, and its corner radius.
    public static let padX = 0.55
    public static let padY = 0.32
    public static let radius = 0.38
    /// Unboxed light words carry a soft shadow (in the picture itself), so
    /// they read over a bright screen: offset down and blur sigma in ems.
    public static let shadowOffset = 0.035
    public static let shadowSigma = 0.07
    public static let shadowAlpha = 0.5
    public static func hasShadow(tone: TextTone, backing: Bool) -> Bool { !backing && tone != .dark }

    static func smooth(_ x: Double) -> Double {
        let u = min(max(x, 0), 1)
        return u * u * (3 - 2 * u)
    }
    static func easeOut(_ x: Double) -> Double {
        let u = min(max(x, 0), 1)
        return 1 - pow(1 - u, 3)
    }
    static func easeOutBack(_ x: Double) -> Double {
        let u = min(max(x, 0), 1), c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(u - 1, 3) + c1 * pow(u - 1, 2)
    }

    /// The words, split as both apps split them.
    public static func words(_ line: String) -> [String] {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    /// The text at output time `t` on a canvas `width` x `height`; nil when it isn't showing.
    public static func state(_ o: TextOverlay, at t: Double, width: Double, height: Double) -> TextState? {
        guard o.duration > 0.01, o.covers(t) else { return nil }
        let shown = o.uppercase ? o.text.uppercased() : o.text
        let lines = shown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let short = min(width, height)
        let px = (o.style.em * min(max(o.size, 0.25), 4) * short).rounded()
        let into = t - o.at, left = o.end - t
        let inDur = min(o.animation == .pop ? 0.32 : 0.45, o.duration / 4)
        let outDur = min(0.35, o.duration / 4)
        let u = into / inDur
        var opacity = smooth(left / outDur)
        var scale = 1.0
        var rise = 0.0
        var arrive: [Double] = []
        switch o.animation {
        case .fade:
            opacity = min(opacity, smooth(u))
        case .rise:
            opacity = min(opacity, smooth(u))
            rise = (1 - easeOut(u)) * 0.035 * short
        case .pop:
            opacity = min(opacity, smooth(u * 1.6))
            scale = 0.82 + 0.18 * easeOutBack(u)
        case .words:
            let n = lines.reduce(0) { $0 + words($1).count }
            // The words arrive over the first ~60% of the text's time, at most 0.32 s apart.
            let step = min(0.32, o.duration * 0.6 / Double(max(n, 1)))
            arrive = (0..<n).map { k in smooth((into - Double(k) * step) / 0.22) }
        }
        return TextState(lines: lines, px: px, tracking: o.style.tracking, centerX: (o.x * width).rounded(),
                         centerY: (o.y * height).rounded() + rise, opacity: opacity, scale: scale, words: arrive)
    }
}

/// Pure edits to the texts.
public enum TextEdits {
    public static let minLength = 0.4

    /// A new text at output time `t`, lasting `duration` but never past the
    /// end of the video (and pulled back if it would start too near it).
    public static func insert(_ text: String, style: TextStyle, animation: TextAnimation, at t: Double, videoLength: Double,
                              duration: Double = 3) -> TextOverlay {
        let length = max(minLength, min(duration, videoLength))
        let start = max(0, min(t, videoLength - length))
        return TextOverlay(text: text, at: start, duration: max(minLength, min(length, videoLength - start)), style: style, animation: animation)
    }

    /// Moves a text to start at `at`, kept inside the video.
    public static func move(_ o: TextOverlay, to at: Double, videoLength: Double) -> TextOverlay {
        var o = o
        o.at = max(0, min(at, videoLength - o.duration))
        return o
    }

    /// Moves one end of a text to `t`, at least `minLength` long and inside the video.
    public static func resize(_ o: TextOverlay, leading: Bool, to t: Double, videoLength: Double) -> TextOverlay {
        var o = o
        if leading {
            let a = max(0, min(t, o.end - minLength))
            o.duration = o.end - a
            o.at = a
        } else {
            o.duration = max(minLength, min(t, videoLength) - o.at)
        }
        return o
    }
}
