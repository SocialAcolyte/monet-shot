import AppKit
import QuartzCore
import MonetShotKit

/// Logs the pointer while a recording runs: its position 120 times a second
/// and every mouse-down, normalised to the recorded content's rectangle.
/// Polling the position and a global mouse monitor need no Accessibility
/// permission (only key events would). Runs only between `start` and `stop`.
@MainActor
final class CursorTracker {
    /// The captured content in global CoreGraphics coordinates (points,
    /// origin top-left of the main display), as ScreenCaptureKit reports it.
    private let content: CGRect
    private var t0: CFTimeInterval?
    private var timer: Timer?
    private var monitors: [Any] = []
    private(set) var samples: [CursorSample] = []
    private(set) var clicks: [CursorSample] = []
    /// Called when Shift is tapped twice quickly on its own (pause/resume).
    var onDoubleShift: () -> Void = {}
    private var shiftDownAt: Double?
    private var lastShiftTapAt: Double?

    init(content: CGRect) { self.content = content }

    func start() {
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)   // keeps firing while menus track
        self.timer = timer
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor in self?.click() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.click() }
            return e
        }) { monitors.append(l) }
    }

    /// Sets time zero: the moment the first frame was written.
    func markStart() {
        let now = CACurrentMediaTime()
        // Re-time anything logged before the file began, and drop what can't be shown.
        if let old = t0 {
            let shift = now - old
            samples = samples.map { CursorSample(t: $0.t - shift, x: $0.x, y: $0.y) }.filter { $0.t >= -0.05 }
            clicks = clicks.map { CursorSample(t: $0.t - shift, x: $0.x, y: $0.y) }.filter { $0.t >= 0 }
        }
        t0 = now
    }

    func stop() -> CursorTrack {
        timer?.invalidate()
        timer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        return CursorTrack(samples: samples, clicks: clicks)
    }

    private var now: Double {
        if t0 == nil { t0 = CACurrentMediaTime() }
        return CACurrentMediaTime() - t0!
    }

    private func normalised() -> (x: Double, y: Double) {
        let p = NSEvent.mouseLocation   // AppKit: origin bottom-left of the main display
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let gx = p.x, gy = mainHeight - p.y   // to CoreGraphics global (origin top-left)
        return ((gx - content.minX) / max(content.width, 1), (gy - content.minY) / max(content.height, 1))
    }

    /// Recording time now (seconds since the first frame).
    var currentTime: Double { now }

    private func sample() {
        watchShift()
        let p = normalised()
        if let last = samples.last, abs(last.x - p.x) < 1e-5, abs(last.y - p.y) < 1e-5,
           now - last.t < 0.5 { return }   // still pointer: one sample every half second is enough
        samples.append(CursorSample(t: now, x: p.x, y: p.y))
    }

    /// Double-tap Shift, read from the modifier state (no permission needed,
    /// unlike watching key events). A tap is a short press of Shift alone; two
    /// starting within 0.35 s of each other fire once. Typing capitals rarely does this: each Shift
    /// there is held across a letter.
    private func watchShift() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let shift = flags.contains(.maskShift)
        let others = !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
        let t = now
        if shift && !others {
            if shiftDownAt == nil { shiftDownAt = t }
        } else if let down = shiftDownAt {
            shiftDownAt = nil
            guard !others, t - down < 0.25 else { lastShiftTapAt = nil; return }
            if let last = lastShiftTapAt, down - last < 0.35 {
                lastShiftTapAt = nil
                onDoubleShift()
            } else {
                lastShiftTapAt = t
            }
        }
    }

    private func click() {
        let p = normalised()
        clicks.append(CursorSample(t: now, x: p.x, y: p.y))
    }

    /// The last moment before `end` that the pointer was below the menu bar,
    /// so a recording can stop before the hand goes up to press Stop.
    static func lastTimeBelowMenuBar(_ samples: [CursorSample], end: Double, menuBarFraction: Double) -> Double? {
        for s in samples.reversed() where s.t <= end {
            if s.y > menuBarFraction { return s.t }
        }
        return nil
    }
}
