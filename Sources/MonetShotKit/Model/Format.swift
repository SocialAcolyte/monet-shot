import Foundation

/// A format is a look and a pace in one go: how fast the clips play, how
/// they cut or fade, how deep the zooms go, the backdrop, the cursor's
/// glide, how texts come in, and the kind of music to look for. Applying
/// one writes all of that into the edit, so everything stays adjustable
/// afterwards; the edit remembers which format it came from (`EditDoc.format`).
public struct EditFormat: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let blurb: String
    /// Every clip's speed.
    public let speed: Double
    /// Fades on every clip (output seconds), and longer ones at the very start and end.
    public let clipFade: Double
    public let openFade: Double
    public let closeFade: Double
    /// Depth of the auto zooms (hand-made ones keep theirs).
    public let zoomScale: Double
    public let backdrop: Backdrop
    public let padding: Double
    public let cornerRadius: Double
    public let cursorSmoothing: Double
    /// How each text style comes in, and whether titles are in capitals.
    public let titleAnimation: TextAnimation
    public let captionAnimation: TextAnimation
    public let labelAnimation: TextAnimation
    public let uppercaseTitles: Bool
    /// The music browser's mood to suggest (`MusicMood.id`).
    public let musicMood: String

    public static let clean = EditFormat(
        id: "clean", name: "Clean", blurb: "The everyday look: real time, straight cuts, gentle zooms.",
        speed: 1, clipFade: 0, openFade: 0, closeFade: 0, zoomScale: 2, backdrop: .paper, padding: 0.07, cornerRadius: 0.018,
        cursorSmoothing: 0.6, titleAnimation: .rise, captionAnimation: .words, labelAnimation: .pop, uppercaseTitles: false,
        musicMood: "sunny")
    public static let fast = EditFormat(
        id: "fast", name: "Fast pace", blurb: "Half as fast again, hard cuts, deep zooms and words that pop.",
        speed: 1.5, clipFade: 0, openFade: 0, closeFade: 0.3, zoomScale: 2.4, backdrop: .slate, padding: 0.05, cornerRadius: 0.024,
        cursorSmoothing: 0.35, titleAnimation: .pop, captionAnimation: .words, labelAnimation: .pop, uppercaseTitles: true,
        musicMood: "grooving")
    public static let melancholic = EditFormat(
        id: "melancholic", name: "Melancholic", blurb: "Slower, every clip fading through dusk, soft zooms, quiet words.",
        speed: 0.85, clipFade: 0.8, openFade: 1.6, closeFade: 2, zoomScale: 1.6, backdrop: .dusk, padding: 0.1, cornerRadius: 0.03,
        cursorSmoothing: 0.85, titleAnimation: .fade, captionAnimation: .fade, labelAnimation: .fade, uppercaseTitles: false,
        musicMood: "mellow")
    public static let cinematic = EditFormat(
        id: "cinematic", name: "Cinematic", blurb: "Opens and closes on long fades, brief dips between clips, titles in capitals.",
        speed: 1, clipFade: 0.35, openFade: 1.4, closeFade: 1.4, zoomScale: 1.8, backdrop: .charcoal, padding: 0.06, cornerRadius: 0.012,
        cursorSmoothing: 0.75, titleAnimation: .rise, captionAnimation: .fade, labelAnimation: .fade, uppercaseTitles: true,
        musicMood: "dreamy")

    public static let all: [EditFormat] = [.clean, .fast, .melancholic, .cinematic]

    public static func named(_ id: String?) -> EditFormat? { all.first { $0.id == id } }

    /// `doc` in this format. `duration` is the first take's (for an edit
    /// whose clips are still derived from its trim and cuts).
    public func apply(to doc: EditDoc, duration: Double) -> EditDoc {
        var d = doc
        var clips = doc.keptClips(duration: duration)
        for i in clips.indices {
            clips[i].speed = speed
            clips[i].fadeIn = i == 0 ? openFade : clipFade
            clips[i].fadeOut = i == clips.count - 1 ? closeFade : clipFade
        }
        d.clips = clips
        d.cuts = []
        d.trimStart = 0
        d.trimEnd = nil
        for i in d.segments.indices where d.segments[i].auto { d.segments[i].scale = zoomScale }
        // A picture of your own stays; the colours follow the format.
        if d.backdrop != .image { d.backdrop = backdrop }
        d.padding = padding
        d.cornerRadius = cornerRadius
        d.cursorSmoothing = cursorSmoothing
        if let texts = d.texts { d.texts = texts.map(styled) }
        d.format = id
        return d
    }

    /// A text as this format brings it in.
    public func styled(_ o: TextOverlay) -> TextOverlay {
        var o = o
        switch o.style {
        case .title:
            o.animation = titleAnimation
            o.uppercase = uppercaseTitles
        case .caption: o.animation = captionAnimation
        case .label: o.animation = labelAnimation
        }
        return o
    }
}
