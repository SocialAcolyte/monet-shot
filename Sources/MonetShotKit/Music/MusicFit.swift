import Foundation

/// Where someone is talking in a take's sound, found by its level alone (no
/// transcript): any voice track counts, the camera's mic or a voiceover.
/// The music ducks under these ranges.
public enum VoiceActivity {
    /// Seconds per level frame.
    public static let hop = 0.05
    /// A pause shorter than this is still talking.
    public static let bridge = 0.5
    /// A burst shorter than this is a click, a breath or a bump, not a voice.
    public static let shortest = 0.2

    /// Level (dBFS, RMS) of each `hop`-long frame of mono `samples` at `rate` Hz.
    public static func levels(_ samples: [Float], rate: Double) -> [Double] {
        let n = max(1, Int((rate * hop).rounded()))
        let frames = samples.count / n
        var out = [Double](repeating: -120, count: frames)
        for f in 0..<frames {
            var e = 0.0
            for i in (f * n)..<(f * n + n) { e += Double(samples[i]) * Double(samples[i]) }
            out[f] = max(-120, 10 * log10(e / Double(n) + 1e-12))
        }
        return out
    }

    /// The level above which a frame is voice: well over the take's own
    /// quiet (its 10th percentile), never below -48 dBFS (silence), never
    /// above -26 dBFS (a take that's talk from end to end).
    public static func threshold(_ levels: [Double]) -> Double {
        guard !levels.isEmpty else { return 0 }
        let sorted = levels.sorted()
        let floor = sorted[min(sorted.count - 1, sorted.count / 10)]
        return min(max(floor + 12, -48), -26)
    }

    /// Talking ranges in seconds from the levels of `hop`-long frames.
    public static func ranges(_ levels: [Double]) -> [ClosedRange<Double>] {
        let thr = threshold(levels)
        var runs: [(Int, Int)] = []
        var start: Int?
        for (i, l) in levels.enumerated() {
            if l >= thr { if start == nil { start = i } } else if let s = start { runs.append((s, i)); start = nil }
        }
        if let s = start { runs.append((s, levels.count)) }
        // close short pauses, then drop what's too short to be a voice
        var merged: [(Int, Int)] = []
        let gap = Int((bridge / hop).rounded())
        for r in runs {
            if let last = merged.last, r.0 - last.1 <= gap { merged[merged.count - 1].1 = r.1 } else { merged.append(r) }
        }
        let least = Int((shortest / hop).rounded())
        return merged.filter { $0.1 - $0.0 >= least }.map { Double($0.0) * hop...Double($0.1) * hop }
    }

    /// Talking ranges of mono `samples` at `rate` Hz.
    public static func ranges(samples: [Float], rate: Double) -> [ClosedRange<Double>] {
        ranges(levels(samples, rate: rate))
    }
}

/// How a song sits under a video: start on a downbeat, and end with the fade
/// beginning on a phrase line (every four bars), so the music finishes its
/// phrase and falls away with the video instead of being chopped mid-bar.
public enum MusicFit {
    /// The plain fade at the end when the song has no beat to go by.
    public static let plainOutro = 2.0

    /// Bar lines of `g` at or before `t` (song time).
    static func line(before t: Double, grid g: MusicGrid, every bars: Int) -> Double {
        let step = g.bar * Double(bars)
        return g.firstDownbeat + ((t - g.firstDownbeat) / step).rounded(.down) * step
    }

    /// The shortest fade the end may have: a bar, and never under 1.5 s.
    static func shortestOutro(_ g: MusicGrid) -> Double { max(1.5, g.bar) }

    /// From the last phrase line that leaves at least the shortest fade, to `end`.
    static func phraseFade(grid g: MusicGrid, end: Double) -> Double {
        end - line(before: end - shortestOutro(g), grid: g, every: 4)
    }

    /// Seconds the fade at the end lasts for music played from `offset` under
    /// a video `length` long: from the last phrase line that leaves at least a
    /// bar, or from the last bar line if that phrase line is far back; never
    /// over a third of the video.
    public static func outro(grid: MusicGrid?, offset: Double, length: Double) -> Double {
        let cap = length / 3
        guard let g = grid, g.bar > 0, length > 0 else { return min(plainOutro, cap) }
        let end = offset + length
        let phrase = phraseFade(grid: g, end: end)
        let fade = phrase <= max(2 * g.bar, 4) ? phrase : end - line(before: end - shortestOutro(g), grid: g, every: 1)
        return max(0, min(fade, cap))
    }

    /// Where in the song a video `length` long starts, and its outro: on a
    /// downbeat at or just after `from` (the song's own good start, or its
    /// first lift for a punchy edit), moved on by up to three bars so the
    /// end fade begins on a phrase line, and kept inside the song when it can be.
    public static func place(grid: MusicGrid?, songDuration: Double, length: Double, from: Double? = nil, punchy: Bool = false) -> (offset: Double, outro: Double) {
        guard let g = grid, g.bar > 0, length > 0 else {
            let o = min(max(0, from ?? 0), max(0, songDuration - length))
            return (o, min(plainOutro, max(0, length / 3)))
        }
        var start = max(0, from ?? g.firstDownbeat)
        if punchy, let lift = g.lifts.first(where: { $0 >= start - 0.01 && $0 + length <= songDuration }) { start = lift }
        // four downbeats from the one at or after `start`; the one whose end fade is shortest
        func choices(from t: Double) -> [Double] {
            let at = line(before: t + 0.001, grid: g, every: 1)
            let down = at < t - 0.001 ? at + g.bar : at
            return (0..<4).map { down + Double($0) * g.bar }.filter { $0 + length <= songDuration + 0.01 }
        }
        var options = choices(from: start)
        if options.isEmpty { options = choices(from: max(0, g.firstDownbeat)) }
        guard !options.isEmpty else {
            let down = max(0, g.firstDownbeat)
            return (down, outro(grid: g, offset: down, length: length))
        }
        // the one whose last phrase ends closest before the video does
        var best = options[0]
        for s in options.dropFirst() where phraseFade(grid: g, end: s + length) < phraseFade(grid: g, end: best + length) - 1e-9 {
            best = s
        }
        return (best, outro(grid: g, offset: best, length: length))
    }
}

/// Calm, steady or upbeat: how fast a song feels.
public enum MusicTempo: String, CaseIterable, Sendable, Identifiable {
    case calm, steady, upbeat
    public var id: String { rawValue }
    public var name: String { rawValue.capitalized }

    /// The library says; otherwise its beats per minute do.
    public static func of(_ s: Song) -> MusicTempo? {
        if let t = s.tempo, let v = MusicTempo(rawValue: t) { return v }
        guard let bpm = s.bpm ?? s.grid.map({ Int($0.bpm.rounded()) }) else { return nil }
        return bpm < 90 ? .calm : bpm <= 115 ? .steady : .upbeat
    }
}

/// A few tracks that suit this video, best first: its format's mood, its
/// length (a song that runs out loops), and for a vertical video, energy.
public enum MusicSuggest {
    public static func score(_ s: Song, length: Double, mood: String?, vertical: Bool, favourite: Bool) -> Double {
        var x = 0.0
        if let mood, s.genres.contains(mood) { x += 3 }
        let energy = s.energy ?? 0.5
        let tempo = MusicTempo.of(s)
        if vertical {
            x += 2.5 * energy + (tempo == .upbeat ? 1 : tempo == .calm ? -1 : 0)
        } else {
            x += 1 - abs(energy - 0.5)
        }
        let playable = s.duration - (s.start ?? 0)
        if length > 0 {
            x += playable >= length ? 1 : -4 * (1 - max(0, playable) / length)
        }
        if favourite { x += 0.75 }
        return x
    }

    /// The best `count` of `songs`, ties kept in library order.
    public static func rank(_ songs: [Song], length: Double, mood: String?, vertical: Bool,
                            favourites: Set<String> = [], count: Int = 6) -> [Song] {
        let scored = songs.enumerated().map { (i, s) in
            (i, s, score(s, length: length, mood: mood, vertical: vertical, favourite: favourites.contains(s.id)))
        }
        return scored.sorted { a, b in
            abs(a.2 - b.2) > 1e-9 ? a.2 > b.2 : a.0 < b.0
        }.prefix(count).map(\.1)
    }
}
