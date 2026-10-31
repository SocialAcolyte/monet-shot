import Foundation

/// A rectangle in a take's picture, normalised: (0,0) is the top-left corner
/// of the recorded frame, (1,1) the bottom-right. The same space as the
/// cursor log, so it stays put whatever the canvas, padding or zoom.
public struct NormRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }

    public static let full = NormRect(x: 0, y: 0, w: 1, h: 1)

    public var isFull: Bool { x <= 1e-4 && y <= 1e-4 && w >= 1 - 1e-4 && h >= 1 - 1e-4 }
    public var maxX: Double { x + w }
    public var maxY: Double { y + h }

    /// Kept inside the frame and at least `minSize` across.
    public func clamped(minSize: Double = 0.02) -> NormRect {
        let w = min(max(self.w, minSize), 1), h = min(max(self.h, minSize), 1)
        return NormRect(x: min(max(x, 0), 1 - w), y: min(max(y, 0), 1 - h), w: w, h: h)
    }

    /// The rectangle spanned by two corners, in either order.
    public static func spanning(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> NormRect {
        NormRect(x: min(a.x, b.x), y: min(a.y, b.y), w: abs(a.x - b.x), h: abs(a.y - b.y))
    }

    /// A point of the whole frame in this rectangle's own 0...1 coordinates.
    public func local(_ px: Double, _ py: Double) -> (x: Double, y: Double) {
        ((px - x) / max(w, 1e-6), (py - y) / max(h, 1e-6))
    }

    /// A point in this rectangle's own coordinates, back in the whole frame.
    public func global(_ u: Double, _ v: Double) -> (x: Double, y: Double) {
        (x + u * w, y + v * h)
    }

    /// Slid by (dx, dy), stopping at the frame's edges.
    public func moved(dx: Double, dy: Double) -> NormRect {
        NormRect(x: min(max(x + dx, 0), 1 - w), y: min(max(y + dy, 0), 1 - h), w: w, h: h)
    }

    /// Resized by dragging one handle by (dx, dy). The handle is named by
    /// where it sits: 0 = the left/top edge, 1 = the right/bottom edge,
    /// 0.5 = the middle (that axis doesn't change). The opposite edges stay put.
    public func resized(handleX hx: Double, handleY hy: Double, dx: Double, dy: Double, minSize m: Double = 0.02) -> NormRect {
        var x0 = x, x1 = maxX, y0 = y, y1 = maxY
        if hx < 0.25 { x0 = min(max(x0 + dx, 0), x1 - m) } else if hx > 0.75 { x1 = max(min(x1 + dx, 1), x0 + m) }
        if hy < 0.25 { y0 = min(max(y0 + dy, 0), y1 - m) } else if hy > 0.75 { y1 = max(min(y1 + dy, 1), y0 + m) }
        return NormRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }
}

/// How a hidden part of the recording looks.
public enum BlurStyle: String, Codable, CaseIterable, Sendable {
    case blur, pixelate, solid

    public var label: String {
        switch self {
        case .blur: "Blur"
        case .pixelate: "Pixelate"
        case .solid: "Cover"
        }
    }
}

/// A part of the recording hidden in the finished video: a chat, an email,
/// a password. It lives on the footage like a zoom does (take and take time),
/// and is drawn into the raw frame before any framing or zoom, so it stays
/// over what it hides however the camera moves.
public struct BlurRegion: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var take: Int
    public var rect: NormRect
    public var style: BlurStyle
    /// 0 = light, 1 = heavy.
    public var strength: Double
    /// Take time it appears and goes; nil = from the start / to the end.
    public var start: Double?
    public var end: Double?

    public init(id: UUID = UUID(), take: Int = 0, rect: NormRect, style: BlurStyle = .blur, strength: Double = 0.6,
                start: Double? = nil, end: Double? = nil) {
        self.id = id
        self.take = take
        self.rect = rect
        self.style = style
        self.strength = strength
        self.start = start
        self.end = end
    }

    public var always: Bool { start == nil && end == nil }

    public func covers(_ t: Double) -> Bool {
        (start.map { t >= $0 } ?? true) && (end.map { t < $0 } ?? true)
    }
}

/// The part of a take that makes the picture: everything outside is left
/// out, and the kept part is framed on the canvas as if it were the whole.
public struct TakeCrop: Codable, Equatable, Sendable {
    public var take: Int
    public var rect: NormRect
    public init(take: Int, rect: NormRect) { self.take = take; self.rect = rect }
}

extension EditDoc {
    /// Take `take`'s crop (the whole frame when it has none).
    public func crop(take: Int) -> NormRect {
        crops.first { $0.take == take }?.rect ?? .full
    }

    /// Sets take `take`'s crop; the whole frame removes it.
    public mutating func setCrop(_ rect: NormRect, take: Int) {
        crops.removeAll { $0.take == take }
        if !rect.isFull { crops.append(TakeCrop(take: take, rect: rect.clamped(minSize: 0.1))) }
        crops.sort { $0.take < $1.take }
    }
}
