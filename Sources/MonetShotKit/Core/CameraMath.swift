import Foundation

/// A pointer path resampled at a fixed rate and smoothed, so it can be read
/// at any time cheaply and identically by the preview and the export.
public struct SmoothTrack: Sendable, Equatable {
    public static let rate: Double = 120
    public let xs: [Double]
    public let ys: [Double]

    public init(xs: [Double], ys: [Double]) {
        self.xs = xs
        self.ys = ys
    }

    /// Position at time `t` (seconds), linearly between samples, clamped to the ends.
    public func position(at t: Double) -> (x: Double, y: Double) {
        guard !xs.isEmpty else { return (0.5, 0.5) }
        let f = max(0, t * Self.rate)
        let i = min(Int(f), xs.count - 1)
        let j = min(i + 1, xs.count - 1)
        let a = f - Double(i)
        return (xs[i] + (xs[j] - xs[i]) * a, ys[i] + (ys[j] - ys[i]) * a)
    }

    /// Resamples `samples` at `rate` over [0, duration] and runs a critically
    /// damped spring over it twice, forwards then backwards. Running it both
    /// ways cancels the lag a one-way filter adds, so the smoothed cursor
    /// still arrives at a button exactly when the click happens.
    /// `omega` is the spring's stiffness (rad/s): higher follows more tightly.
    public static func make(from samples: [CursorSample], duration: Double, omega: Double) -> SmoothTrack {
        let n = max(2, Int((duration * rate).rounded(.up)) + 1)
        guard let first = samples.first else {
            return SmoothTrack(xs: Array(repeating: 0.5, count: n), ys: Array(repeating: 0.5, count: n))
        }
        var rawX = [Double](repeating: first.x, count: n)
        var rawY = [Double](repeating: first.y, count: n)
        var k = 0
        for i in 0..<n {
            let t = Double(i) / rate
            while k + 1 < samples.count && samples[k + 1].t <= t { k += 1 }
            let a = samples[k]
            if k + 1 < samples.count, t > a.t {
                let b = samples[k + 1]
                let u = (t - a.t) / max(b.t - a.t, 1e-6)
                rawX[i] = a.x + (b.x - a.x) * u
                rawY[i] = a.y + (b.y - a.y) * u
            } else {
                rawX[i] = a.x
                rawY[i] = a.y
            }
        }
        // Hold the first and last positions for a second either side, so each
        // pass has settled before it reaches real data at either end.
        let pad = Int(rate)
        func smoothed(_ raw: [Double]) -> [Double] {
            let padded = Array(repeating: raw[0], count: pad) + raw + Array(repeating: raw[raw.count - 1], count: pad)
            let both = Array(spring(spring(padded, omega: omega).reversed(), omega: omega).reversed())
            return Array(both[pad..<(pad + raw.count)])
        }
        return SmoothTrack(xs: smoothed(rawX), ys: smoothed(rawY))
    }

    /// One pass of a critically damped spring chasing `target`, stepped at `rate`.
    static func spring<S: Sequence>(_ target: S, omega: Double) -> [Double] where S.Element == Double {
        let values = Array(target)
        guard var x = values.first else { return [] }
        var v = 0.0
        let dt = 1 / rate
        // Sub-step so stiff springs stay stable (omega * h well under 1).
        let steps = max(1, Int((omega * dt / 0.25).rounded(.up)))
        let h = dt / Double(steps)
        var out = [Double]()
        out.reserveCapacity(values.count)
        for goal in values {
            for _ in 0..<steps {
                v += (omega * omega * (goal - x) - 2 * omega * v) * h
                x += v * h
            }
            out.append(x)
        }
        return out
    }
}

/// Where the virtual camera is looking at one moment: a zoom factor and the
/// centre of the view, in normalised content coordinates.
public struct Camera: Equatable, Sendable {
    public var scale: Double
    public var centerX: Double
    public var centerY: Double

    public static let identity = Camera(scale: 1, centerX: 0.5, centerY: 0.5)

    /// The visible part of the content (normalised, top-left origin).
    public var viewport: (x: Double, y: Double, w: Double, h: Double) {
        let w = 1 / scale, h = 1 / scale
        return (centerX - w / 2, centerY - h / 2, w, h)
    }

    /// Maps a normalised content point to normalised viewport coordinates
    /// (0...1 across the framed picture; outside that range is off-screen).
    public func project(x: Double, y: Double) -> (x: Double, y: Double) {
        let v = viewport
        return ((x - v.x) / v.w, (y - v.y) / v.h)
    }
}

public enum CameraMath {
    /// Seconds the camera takes to zoom in, and again to zoom out.
    public static let ramp: Double = 0.75
    /// Clicks closer together than this become one zoom.
    public static let clusterGap: Double = 2.6
    /// How long a zoom starts before its first click, and holds after its last.
    public static let leadIn: Double = 0.9
    public static let holdAfter: Double = 1.7
    public static let defaultScale: Double = 2.0
    /// Two zooms closer than this become one that pans between them, rather
    /// than dipping out and straight back in.
    public static let mergeGap: Double = 2.5

    /// Spring stiffness for the visible cursor, from the 0...1 smoothing setting.
    public static func cursorOmega(smoothing: Double) -> Double {
        let s = min(max(smoothing, 0), 1)
        return 60 * pow(8.0 / 60.0, s)   // 60 rad/s (tight) ... 8 rad/s (glide)
    }

    /// The camera follows a much lazier copy of the cursor, so it pans
    /// calmly instead of chasing every flick of the hand.
    public static let cameraOmega: Double = 3.2

    /// Zoom segments made from clicks: clicks are grouped when they come
    /// close together; each group zooms in a little before its first click
    /// and holds a little after its last. Groups that would overlap or leave
    /// a gap too short to zoom out and back in are merged.
    public static func autoZooms(clicks: [CursorSample], duration: Double, scale: Double = defaultScale, take: Int = 0) -> [ZoomSegment] {
        let sorted = clicks.filter { $0.t >= 0 && $0.t <= duration }.sorted { $0.t < $1.t }
        guard !sorted.isEmpty else { return [] }
        var groups: [[CursorSample]] = [[sorted[0]]]
        for c in sorted.dropFirst() {
            if c.t - groups[groups.count - 1].last!.t < clusterGap {
                groups[groups.count - 1].append(c)
            } else {
                groups.append([c])
            }
        }
        var spans: [(Double, Double)] = groups.map { g in
            (max(0, g.first!.t - leadIn), min(duration, g.last!.t + holdAfter))
        }
        var merged: [(Double, Double)] = []
        for s in spans.sorted(by: { $0.0 < $1.0 }) {
            if let last = merged.last, s.0 - last.1 < mergeGap {
                merged[merged.count - 1].1 = max(last.1, s.1)
            } else {
                merged.append(s)
            }
        }
        spans = merged
        return spans
            .filter { $0.1 - $0.0 >= ramp }
            .map { ZoomSegment(start: $0.0, end: $0.1, scale: scale, auto: true, take: take) }
    }

    /// 0 outside the segment, rising to 1 over `ramp` (or half the segment if
    /// it is short), holding, then falling back to 0 at its end.
    public static func weight(_ s: ZoomSegment, at t: Double) -> Double {
        guard t > s.start, t < s.end else { return 0 }
        let r = min(ramp, s.duration / 2)
        guard r > 0 else { return 0 }
        let up = (t - s.start) / r
        let down = (s.end - t) / r
        return ease(min(1, min(up, down)))
    }

    /// Smootherstep: zero velocity and zero acceleration at both ends, so a
    /// zoom starts and lands without a jolt.
    public static func ease(_ u: Double) -> Double {
        let x = min(max(u, 0), 1)
        return x * x * x * (x * (x * 6 - 15) + 10)
    }

    /// The camera at time `t`. Where segments overlap, the stronger one wins.
    /// The centre is the focus point clamped so the view never leaves the
    /// recording; at 1x that clamp pins it to the middle, so zooming out
    /// glides home on its own.
    public static func camera(at t: Double, segments: [ZoomSegment], focus: SmoothTrack) -> Camera {
        var best: (seg: ZoomSegment, w: Double)?
        for s in segments {
            let w = weight(s, at: t)
            if w > 0, w > (best?.w ?? 0) { best = (s, w) }
        }
        guard let (seg, w) = best else { return .identity }
        let scale = 1 + (max(seg.scale, 1) - 1) * w
        let f: (x: Double, y: Double) = seg.followsCursor ? focus.position(at: t) : (seg.focusX!, seg.focusY!)
        let half = 0.5 / scale
        return Camera(scale: scale,
                      centerX: min(max(f.x, half), 1 - half),
                      centerY: min(max(f.y, half), 1 - half))
    }

    /// How far through its ripple each recent click is (0 = just clicked,
    /// 1 = gone), for clicks in the last `duration` seconds.
    public static func ripples(clicks: [CursorSample], at t: Double, duration: Double = 0.55) -> [(click: CursorSample, progress: Double)] {
        clicks.compactMap { c in
            let age = t - c.t
            return age >= 0 && age < duration ? (c, age / duration) : nil
        }
    }

    /// The cursor dips to this scale for a moment on each click, then springs back.
    public static func pressScale(clicks: [CursorSample], at t: Double) -> Double {
        var s = 1.0
        for c in clicks {
            let age = t - c.t
            if age >= -0.04 && age < 0.22 {
                let u = max(0, age) / 0.22
                s = min(s, 1 - 0.18 * sin(Double.pi * min(1, u + 0.18)))
            }
        }
        return s
    }
}

/// Pure edits to the segment list, kept here so the editor's drag handling
/// is testable without a window.
public enum SegmentEdits {
    public static let minDuration: Double = 0.4

    /// Moves a segment by `delta` seconds, kept inside [0, duration].
    public static func move(_ s: ZoomSegment, by delta: Double, duration: Double) -> ZoomSegment {
        var out = s
        let d = min(max(delta, -s.start), duration - s.end)
        out.start += d
        out.end += d
        out.auto = false
        return out
    }

    /// Drags the left (`leading: true`) or right edge to `time`.
    public static func resize(_ s: ZoomSegment, leading: Bool, to time: Double, duration: Double) -> ZoomSegment {
        var out = s
        if leading {
            out.start = min(max(0, time), s.end - minDuration)
        } else {
            out.end = max(min(duration, time), s.start + minDuration)
        }
        out.auto = false
        return out
    }

    /// A new hand-made segment centred on `time` in take `take`, trimmed to
    /// fit the free space around it among that take's zooms; nil if there is no room.
    public static func insert(at time: Double, into segments: [ZoomSegment], duration: Double, length: Double = 2.5, take: Int = 0) -> ZoomSegment? {
        var lo = 0.0, hi = duration
        for s in segments where s.take == take {
            if s.start <= time && time <= s.end { return nil }
            if s.end <= time { lo = max(lo, s.end) }
            if s.start >= time { hi = min(hi, s.start) }
        }
        let start = max(lo, time - length / 2)
        let end = min(hi, start + length)
        guard end - start >= minDuration else { return nil }
        return ZoomSegment(start: start, end: end, scale: CameraMath.defaultScale, take: take)
    }

    /// Re-runs auto-zoom: hand-made segments stay; auto ones are replaced,
    /// except where a new one would overlap a hand-made one.
    public static func reAuto(_ segments: [ZoomSegment], clicks: [CursorSample], duration: Double, take: Int = 0) -> [ZoomSegment] {
        let others = segments.filter { $0.take != take }
        let manual = segments.filter { !$0.auto && $0.take == take }
        let fresh = CameraMath.autoZooms(clicks: clicks, duration: duration, take: take).filter { a in
            !manual.contains { m in a.start < m.end && m.start < a.end }
        }
        return others + (manual + fresh).sorted { $0.start < $1.start }
    }
}
