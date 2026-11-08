import CoreGraphics
import Foundation

/// The shape a video is made for. Landscape is the edit's own
/// `outputWidth` x `canvasAspect`; the others are fixed phone and feed
/// sizes, and frame a wide recording by following the action
/// (`FollowFraming`). Stored as `EditDoc.layout` (nil = landscape), so
/// switching back leaves the landscape edit exactly as it was.
public enum CanvasLayout: String, Codable, CaseIterable, Sendable {
    case landscape, vertical, square

    public var label: String {
        switch self {
        case .landscape: "Landscape"
        case .vertical: "Vertical"
        case .square: "Square"
        }
    }

    /// The canvas in pixels; nil for landscape (the edit's own size).
    public var size: (width: Int, height: Int)? {
        switch self {
        case .landscape: nil
        case .vertical: (1080, 1920)
        case .square: (1080, 1080)
        }
    }
}

public extension EditDoc {
    var canvasLayout: CanvasLayout { layout ?? .landscape }

    /// Sets the layout; landscape removes the key, so the edit is what it was.
    mutating func setLayout(_ l: CanvasLayout) { layout = l == .landscape ? nil : l }

    /// A wide take is cropped to a window that follows the action.
    var followsAction: Bool { canvasLayout != .landscape }
}

/// The part of a canvas `canvasWidth` x `canvasHeight` (pixels, top-left
/// origin) that phone apps leave clear: on a tall canvas, Reels, Shorts and
/// TikTok cover the top ~12% and bottom ~20% with their own buttons and
/// words, and the sides a little. Any other canvas is clear edge to edge.
/// Texts and captions are placed inside it.
public func safeArea(canvasWidth: Double, canvasHeight: Double) -> CGRect {
    guard canvasHeight > canvasWidth * 1.25 else { return CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight) }
    let side = (canvasWidth * SafeArea.side).rounded()
    let top = (canvasHeight * SafeArea.top).rounded()
    let bottom = (canvasHeight * SafeArea.bottom).rounded()
    return CGRect(x: side, y: top, width: canvasWidth - 2 * side, height: canvasHeight - top - bottom)
}

public enum SafeArea {
    public static let top = 0.12
    public static let bottom = 0.20
    public static let side = 0.08
    /// The bottom of the safe area kept for captions (a fraction of the
    /// canvas height): the vertical camera bubble sits above it.
    public static let captionBand = 0.10

    /// Whether the safe area of this canvas is smaller than the canvas.
    public static func isInset(canvasWidth: Double, canvasHeight: Double) -> Bool { canvasHeight > canvasWidth * 1.25 }
}

/// Follow framing: in a tall (or square) frame, a wide recording is shown
/// through a window of the frame's shape, its full height, which pans to
/// keep the action in view the way a person would operate the camera. It
/// holds still while the action stays near the middle (a dead zone), then
/// glides to it (a critically damped spring run both ways, so it never
/// lags and never drifts). The action is the zoom's target while a zoom
/// holds still on a point, otherwise the calm camera copy of the pointer.
/// Zooms still zoom, a little less deep, since the window is close already.
public enum FollowFraming {
    /// The share of a zoom's depth kept in a follow window (2x becomes 1.6x).
    public static let zoomDepth = 0.6
    /// How far the action may stray from the window's centre before it
    /// moves, as a fraction of the window's width (or height).
    public static let deadZone = 0.22
    /// The glide's stiffness, rad/s: a pan of about a second and a half, under way half a second before the action moves.
    public static let omega = 4.0

    /// The window's shape (normalised width over height) for a take of
    /// `takeAspect` in a frame of `frameAspect`; nil when the take is no
    /// wider than the frame, which then shows it whole.
    public static func window(takeAspect: Double, frameAspect: Double) -> Double? {
        guard frameAspect > 0, takeAspect > frameAspect * 1.001 else { return nil }
        return frameAspect / takeAspect
    }

    /// The zoom segment with the most weight at `t`, and that weight.
    static func strongest(at t: Double, _ segments: [ZoomSegment]) -> (seg: ZoomSegment, w: Double)? {
        var best: (seg: ZoomSegment, w: Double)?
        for s in segments {
            let w = CameraMath.weight(s, at: t)
            if w > 0, w > (best?.w ?? 0) { best = (s, w) }
        }
        return best
    }

    /// The window's zoom at take time `t`.
    public static func scale(at t: Double, segments: [ZoomSegment]) -> Double {
        guard let (seg, w) = strongest(at: t, segments) else { return 1 }
        return 1 + (max(seg.scale, 1) - 1) * zoomDepth * w
    }
}

/// One take's follow path: where the window is centred over the take's
/// time (its cropped picture's 0...1 coordinates), sampled at 120 Hz.
public struct FollowTrack: Sendable, Equatable {
    /// Normalised width over height of the window (below 1).
    public let window: Double
    /// The glide: the window's centre, before it is kept inside the picture.
    public let path: SmoothTrack

    public init(window: Double, path: SmoothTrack) {
        self.window = window
        self.path = path
    }

    /// `focus` is the take's camera copy of the pointer (`CameraMath.cameraOmega`).
    public static func make(window: Double, segments: [ZoomSegment], focus: SmoothTrack, duration: Double) -> FollowTrack {
        let rate = SmoothTrack.rate
        let n = max(2, Int((duration * rate).rounded(.up)) + 1)
        var gx = [Double](repeating: 0.5, count: n)
        var gy = [Double](repeating: 0.5, count: n)
        var x = 0.5, y = 0.5
        for i in 0..<n {
            let t = Double(i) / rate
            let best = FollowFraming.strongest(at: t, segments)
            let s = best.map { 1 + (max($0.seg.scale, 1) - 1) * FollowFraming.zoomDepth * $0.w } ?? 1
            var target = focus.position(at: t)
            if let b = best, let fx = b.seg.focusX, let fy = b.seg.focusY { target = (fx, fy) }
            let w = window / s, h = 1 / s
            // Hold still until the action leaves the dead zone, then aim at it.
            if i == 0 || abs(target.x - x) > FollowFraming.deadZone * w { x = target.x }
            if i == 0 || abs(target.y - y) > FollowFraming.deadZone * h { y = target.y }
            x = min(max(x, w / 2), 1 - w / 2)
            y = min(max(y, h / 2), 1 - h / 2)
            gx[i] = x
            gy[i] = y
        }
        return FollowTrack(window: window, path: SmoothTrack(xs: glide(gx), ys: glide(gy)))
    }

    /// The aims, smoothed by the spring forwards then backwards, with a
    /// second of the first and last aim either side so both passes settle.
    static func glide(_ aims: [Double]) -> [Double] {
        let pad = Int(SmoothTrack.rate)
        let padded = Array(repeating: aims[0], count: pad) + aims + Array(repeating: aims[aims.count - 1], count: pad)
        let both = Array(SmoothTrack.spring(SmoothTrack.spring(padded, omega: FollowFraming.omega).reversed(), omega: FollowFraming.omega).reversed())
        return Array(both[pad..<(pad + aims.count)])
    }

    /// The camera at take time `t`: the glide's centre, kept inside the
    /// picture at that moment's zoom.
    public func camera(at t: Double, segments: [ZoomSegment]) -> Camera {
        let s = FollowFraming.scale(at: t, segments: segments)
        let p = path.position(at: t)
        let w = window / s, h = 1 / s
        return Camera(scale: s, centerX: min(max(p.x, w / 2), 1 - w / 2), centerY: min(max(p.y, h / 2), 1 - h / 2), window: window)
    }
}
