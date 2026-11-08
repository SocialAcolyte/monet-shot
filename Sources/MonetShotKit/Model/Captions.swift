import Foundation

/// What was said in a take, word by word: `transcript.json` in the take's
/// folder. Times are the take's own (like the cursor log), so the words stay
/// on the footage whatever the edit does with it.
public struct Transcript: Codable, Equatable, Sendable {
    /// The words in the order said (sorted by `start`).
    public var words: [TranscriptWord]
    /// The language heard or chosen ("en", "fr", …), if known.
    public var language: String?
    /// What heard it: "apple" (on-device speech on the Mac) or "whisper".
    public var engine: String?

    public init(words: [TranscriptWord], language: String? = nil, engine: String? = nil) {
        self.words = words
        self.language = language
        self.engine = engine
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        words = try c.decodeIfPresent([TranscriptWord].self, forKey: .words) ?? []
        language = try c.decodeIfPresent(String.self, forKey: .language)
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
    }

    public static let fileName = "transcript.json"

    /// The take's transcript, if it has one.
    public static func load(_ takeFolder: URL) -> Transcript? {
        guard let data = try? Data(contentsOf: takeFolder.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder.app.decode(Transcript.self, from: data)
    }

    public func save(_ takeFolder: URL) throws {
        try JSONEncoder.app.encode(self).write(to: takeFolder.appendingPathComponent(Transcript.fileName), options: .atomic)
    }

    /// Word `i` spelled `text` instead; an empty text removes it.
    public func editing(_ i: Int, to text: String) -> Transcript {
        guard words.indices.contains(i) else { return self }
        var t = self
        let clean = Captions.pieces(text).joined(separator: " ")
        if clean.isEmpty { t.words.remove(at: i) } else { t.words[i].text = clean }
        return t
    }
}

public struct TranscriptWord: Codable, Equatable, Sendable {
    public var text: String
    /// Take seconds.
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

/// A transcript word placed in the video (output time), and which clip shows it.
public struct CaptionWord: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public var span: Int
    /// Its take and index in that take's transcript, for editing it.
    public var take: Int
    public var index: Int
}

/// Transcripts turned into captions: short phrases over the bottom of the
/// video, the word being said lit. Pure, and the same in every app
/// (`shared/fixtures/captions.json`).
public enum Captions {
    /// A phrase holds at most this many words, and this many letters.
    public static let maxWords = 6
    public static let maxChars = 38
    /// A phrase longer than this goes on two lines.
    public static let lineChars = 20
    /// A pause this long (seconds) starts a new phrase.
    public static let pause = 0.6
    /// A phrase stays up this long after its last word (unless the next comes first).
    public static let tail = 0.35
    public static let minLength = 0.6

    /// A word split where every app splits (spaces, tabs, line breaks), empty pieces dropped.
    static func pieces(_ s: String) -> [String] {
        s.unicodeScalars.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .map { String(String.UnicodeScalarView($0)) }
    }

    static func length(_ s: String) -> Int { s.unicodeScalars.count }

    /// Every transcribed word the edit shows, in output time and play order.
    /// A word belongs to the clip that shows its middle; `transcripts[k]` is take k's.
    public static func words(_ transcripts: [Transcript?], map: TimeMap) -> [CaptionWord] {
        var out: [CaptionWord] = []
        for (i, s) in map.spans.enumerated() {
            guard transcripts.indices.contains(s.take), let tr = transcripts[s.take] else { continue }
            for (k, w) in tr.words.enumerated() {
                let mid = (w.start + w.end) / 2
                guard mid >= s.start, mid < s.end else { continue }
                let a = max(w.start, s.start), b = min(w.end, s.end)
                for p in pieces(w.text) {
                    out.append(CaptionWord(text: p, start: s.at + (a - s.start) / s.speed, end: s.at + (b - s.start) / s.speed,
                                           span: i, take: s.take, index: k))
                }
            }
        }
        return out
    }

    static func endsSentence(_ s: String) -> Bool {
        guard let last = s.unicodeScalars.last else { return false }
        return ".!?…".unicodeScalars.contains(last)
    }

    /// The words grouped into phrases: a new one after `maxWords` words or
    /// `maxChars` letters, at a pause, after a sentence ends, and at a cut.
    public static func phrases(_ words: [CaptionWord]) -> [[CaptionWord]] {
        var out: [[CaptionWord]] = []
        var cur: [CaptionWord] = []
        var chars = 0
        for w in words {
            if let last = cur.last {
                if cur.count >= maxWords || w.span != last.span || w.start - last.end > pause || endsSentence(last.text)
                    || chars + 1 + length(w.text) > maxChars {
                    out.append(cur)
                    cur = []
                }
            }
            chars = cur.isEmpty ? length(w.text) : chars + 1 + length(w.text)
            cur.append(w)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// A phrase's words as drawn: one line, or two balanced ones.
    public static func lines(_ words: [String]) -> String {
        let total = words.reduce(0) { $0 + length($1) } + max(0, words.count - 1)
        guard total > lineChars, words.count > 1 else { return words.joined(separator: " ") }
        var best = 1, bestDiff = Int.max
        for j in 1..<words.count {
            let a = words[..<j].reduce(0) { $0 + length($1) } + (j - 1)
            let b = total - a - 1
            if abs(a - b) < bestDiff { bestDiff = abs(a - b); best = j }
        }
        return words[..<best].joined(separator: " ") + "\n" + words[best...].joined(separator: " ")
    }

    /// Caption size relative to the caption style's own: bigger on a tall canvas.
    public static func size(canvasWidth w: Double, canvasHeight h: Double) -> Double { h > w ? 1.25 : 1 }

    /// The captions as texts over a `width` x `height` canvas, coming in as
    /// `animation` (the format's caption animation), in output time.
    public static func overlays(_ transcripts: [Transcript?], map: TimeMap, width: Double, height: Double,
                                animation: TextAnimation = .words) -> [TextOverlay] {
        let groups = phrases(words(transcripts, map: map))
        let safe = safeArea(canvasWidth: width, canvasHeight: height)
        let short = min(width, height)
        let size = size(canvasWidth: width, canvasHeight: height)
        let px = (TextStyle.caption.em * size * short).rounded()
        var out: [TextOverlay] = []
        for (k, p) in groups.enumerated() {
            guard let first = p.first, let last = p.last else { continue }
            let next = k + 1 < groups.count ? groups[k + 1][0].start : map.duration
            let end = min(max(last.end + tail, first.start + minLength), next, map.duration)
            guard end - first.start > 0.05 else { continue }
            let text = lines(p.map(\.text))
            let count = text.contains("\n") ? 2.0 : 1.0
            let block = count * TextMotion.lineHeight * px + 2 * TextMotion.padY * px
            // The block's bottom sits a little above the safe area's.
            let y = (Double(safe.maxY) - 0.03 * short - block / 2) / height
            var o = TextOverlay(id: UUID(uuidString: String(format: "C0000000-0000-4000-8000-%012X", k))!, text: text,
                                at: first.start, duration: end - first.start, style: .caption, animation: animation)
            o.x = Double(safe.midX) / width
            o.y = y
            o.size = size
            o.beats = p.map { $0.start - first.start }
            out.append(o)
        }
        return out
    }

    /// The captions as SubRip subtitles.
    public static func srt(_ overlays: [TextOverlay]) -> String {
        func stamp(_ t: Double) -> String {
            let ms = Int((max(0, t) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return overlays.enumerated().map { k, o in
            "\(k + 1)\n\(stamp(o.at)) --> \(stamp(o.end))\n\(o.text)\n"
        }.joined(separator: "\n")
    }

    /// Plain text of everything said, in play order: a new paragraph after a long pause.
    public static func text(_ words: [CaptionWord]) -> String {
        var out = ""
        var prev: CaptionWord?
        for w in words {
            if let p = prev { out += w.start - p.end > 1.5 ? "\n\n" : " " }
            out += w.text
            prev = w
        }
        return out
    }
}
