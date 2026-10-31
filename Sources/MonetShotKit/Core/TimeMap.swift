import Foundation

/// The video as a sequence: each clip (a stretch of one take) played in
/// order. Converts output time (what the player, the timeline and the export
/// run on) to a take and that take's own time (what the cursor log and the
/// zooms use), and back.
public struct TimeMap: Equatable, Sendable {
    public struct Span: Equatable, Sendable {
        public let take: Int
        public let start: Double   // take time
        public let end: Double
        public let at: Double      // where it begins in output time
        public var duration: Double { end - start }
    }

    public let spans: [Span]
    public var duration: Double { spans.last.map { $0.at + $0.duration } ?? 0 }

    /// Clips in play order (not sorted: the order is the edit).
    public init(clips: [Clip]) {
        var at = 0.0
        var spans: [Span] = []
        for c in clips where c.duration > 1e-3 {
            spans.append(Span(take: c.take, start: c.start, end: c.end, at: at))
            at += c.duration
        }
        self.spans = spans
    }

    public init(_ doc: EditDoc, duration: Double) {
        self.init(clips: doc.keptClips(duration: duration))
    }

    /// Which clip plays at output time `t`, and the take and take time there.
    public func locate(_ t: Double) -> (index: Int, take: Int, time: Double) {
        guard let last = spans.last else { return (0, 0, 0) }
        if t <= 0 { return (0, spans[0].take, spans[0].start) }
        for (i, s) in spans.enumerated() where t < s.at + s.duration {
            return (i, s.take, s.start + (t - s.at))
        }
        return (spans.count - 1, last.take, last.end)
    }

    /// Output time of a moment in a take, as it first appears (nil if no
    /// clip shows it).
    public func output(take: Int, time: Double) -> Double? {
        spans.first { $0.take == take && time >= $0.start && time <= $0.end }.map { $0.at + (time - $0.start) }
    }

    /// True if that moment of that take is in the video.
    public func keeps(take: Int, time: Double) -> Bool { output(take: take, time: time) != nil }
}

/// Pure edits to the clip sequence (split, delete, resize, reorder), so the
/// timeline's handling is testable without a window. Times passed to
/// `split` are output times; edges are moved in take time.
public enum ClipEdits {
    public static let minLength: Double = 0.2

    /// Where each clip starts in output time.
    public static func starts(_ clips: [Clip]) -> [Double] {
        var at = 0.0
        return clips.map { c in defer { at += c.duration }; return at }
    }

    /// Splits the clip playing at output time `t` in two; nil if `t` is too
    /// near a clip's edge.
    public static func split(_ clips: [Clip], atOutput t: Double) -> [Clip]? {
        let st = starts(clips)
        for (i, c) in clips.enumerated() {
            let into = t - st[i]
            guard into > 0, into < c.duration else { continue }
            guard into >= minLength / 2, c.duration - into >= minLength / 2 else { return nil }
            var out = clips
            let cut = c.start + into
            out.replaceSubrange(i...i, with: [Clip(start: c.start, end: cut, take: c.take), Clip(start: cut, end: c.end, take: c.take)])
            return out
        }
        return nil
    }

    /// Removes clip `i`; the last clip can't go.
    public static func delete(_ clips: [Clip], at i: Int) -> [Clip] {
        guard clips.indices.contains(i), clips.count > 1 else { return clips }
        var out = clips
        out.remove(at: i)
        return out
    }

    /// Moves an edge of clip `i` to take time `t`, kept inside its take
    /// (0...takeDuration) and at least `minLength` long. The clips after it
    /// simply play earlier or later.
    public static func resize(_ clips: [Clip], at i: Int, leading: Bool, to t: Double, takeDuration: Double) -> [Clip] {
        guard clips.indices.contains(i) else { return clips }
        var out = clips
        if leading {
            out[i].start = min(max(0, t), clips[i].end - minLength)
        } else {
            out[i].end = max(min(takeDuration, t), clips[i].start + minLength)
        }
        return out
    }

    /// Moves clip `from` so it plays at position `to`.
    public static func move(_ clips: [Clip], from: Int, to: Int) -> [Clip] {
        guard clips.indices.contains(from) else { return clips }
        var out = clips
        let c = out.remove(at: from)
        out.insert(c, at: min(max(0, to), out.count))
        return out
    }

    /// Where a dragged clip lands: the slot whose midpoint its centre passed.
    public static func dropIndex(_ clips: [Clip], dragging i: Int, centreAt t: Double) -> Int {
        var others = clips
        guard others.indices.contains(i) else { return i }
        others.remove(at: i)
        let st = starts(others)
        for (k, c) in others.enumerated() where t < st[k] + c.duration / 2 { return k }
        return others.count
    }
}
