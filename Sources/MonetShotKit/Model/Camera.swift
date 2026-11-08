import Foundation

/// You on camera, recorded over the finished video in the editor. Its file
/// sits in the recording folder; `at` is output time (the finished video's
/// clock), so it stays put when clips change underneath it.
public struct CameraClip: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// File name inside the .reel folder.
    public var file: String
    public var at: Double
    public var duration: Double
    /// Fill the frame instead of sitting in a bubble.
    public var full: Bool

    public init(id: UUID = UUID(), file: String, at: Double, duration: Double, full: Bool = false) {
        self.id = id
        self.file = file
        self.at = at
        self.duration = duration
        self.full = full
    }

    public var end: Double { at + duration }
    public func covers(_ t: Double) -> Bool { t >= at && t < end }
}

public enum CameraShape: String, Codable, CaseIterable, Sendable {
    case circle, rounded
    public var label: String { self == .circle ? "Circle" : "Rounded" }
}

public enum CameraCorner: String, Codable, CaseIterable, Sendable {
    case bottomRight, bottomLeft, topRight, topLeft
}

/// How the camera bubble looks: one look for the whole video.
public struct CameraLook: Codable, Equatable, Sendable {
    public var visible = true
    public var shape: CameraShape = .circle
    public var corner: CameraCorner = .bottomRight
    /// Bubble height as a fraction of the canvas's shorter side.
    public var size: Double = 0.27
    /// Show yourself as in a mirror (how the camera preview looks).
    public var mirror = true
    /// Lower the music while you talk.
    public var duckMusic = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CameraLook()
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? d.visible
        shape = try c.decodeIfPresent(CameraShape.self, forKey: .shape) ?? d.shape
        corner = try c.decodeIfPresent(CameraCorner.self, forKey: .corner) ?? d.corner
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        mirror = try c.decodeIfPresent(Bool.self, forKey: .mirror) ?? d.mirror
        duckMusic = try c.decodeIfPresent(Bool.self, forKey: .duckMusic) ?? d.duckMusic
    }
}

public enum CameraEdits {
    /// Adds `clip`, trimming or removing whatever it records over.
    public static func insert(_ clip: CameraClip, into clips: [CameraClip]) -> [CameraClip] {
        var out: [CameraClip] = []
        for c in clips {
            if c.end <= clip.at || c.at >= clip.end { out.append(c); continue }
            // The part before the new clip survives; the part after is cut off
            // (its file would need an offset to resume, and talk rarely does).
            if c.at < clip.at - 0.2 {
                var head = c
                head.duration = clip.at - c.at
                out.append(head)
            }
        }
        out.append(clip)
        return out.sorted { $0.at < $1.at }
    }

    /// The camera fades in and out over this long at a clip's ends.
    public static let fade = 0.28

    /// 0...1: how present clip `c` is at time `t`.
    public static func presence(_ c: CameraClip, at t: Double) -> Double {
        guard c.covers(t) else { return 0 }
        let f = min(fade, c.duration / 3)
        guard f > 0 else { return 1 }
        let x = min(1, min(t - c.at, c.end - t) / f)
        return x * x * (3 - 2 * x)
    }
}

/// The music's level over time, ducked under your voice.
public enum MusicEnvelope {
    public static let duckLevel = 0.3
    public static let duckRamp = 0.45

    /// Gain at output time `t`, as a fraction of the chosen volume. `outro`
    /// is how long the fade at the end lasts (nil = 2 s; never over a third).
    public static func gain(at t: Double, length: Double, fadeIn: Bool, fadeOut: Bool, outro: Double? = nil,
                            voice: [ClosedRange<Double>]) -> Double {
        var g = 1.0
        let fi = min(1.2, length / 3), fo = min(outro ?? 2.0, length / 3)
        if fadeIn, fi > 0, t < fi { g *= max(0, t / fi) }
        if fadeOut, fo > 0, t > length - fo { g *= max(0, (length - t) / fo) }
        var duck = 0.0
        for v in voice {
            let into = min(t - (v.lowerBound - duckRamp), (v.upperBound + duckRamp) - t) / duckRamp
            duck = max(duck, min(1, max(0, into)))
        }
        return g * (1 - duck * (1 - duckLevel))
    }
}
