//! The pointer log kept while a recording runs, and the double-tap Shift
//! detector. Ported from `Sources/MonetShot/Recording/CursorTracker.swift`:
//! same thinning of a still pointer, same re-timing at the first frame, same
//! tap timings. Backends feed it; times are seconds on one monotonic clock.

use std::time::Instant;

/// A position normalised to the captured content: (0,0) top-left of the
/// video frame, (1,1) bottom-right. Same as core's `CursorSample`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Sample {
    pub t: f64,
    pub x: f64,
    pub y: f64,
}

/// Samples and clicks, timed from an origin that `mark_start` moves to the
/// first written frame.
#[derive(Debug)]
pub struct CursorLog {
    origin: Instant,
    started: bool,
    pub samples: Vec<Sample>,
    pub clicks: Vec<Sample>,
}

impl CursorLog {
    pub fn new(origin: Instant) -> Self {
        CursorLog { origin, started: false, samples: Vec::new(), clicks: Vec::new() }
    }

    /// Seconds since the origin (the first frame, once it was marked).
    pub fn time(&self, at: Instant) -> f64 {
        at.saturating_duration_since(self.origin).as_secs_f64() - self.before(at)
    }

    // An instant before the origin gives a negative time.
    fn before(&self, at: Instant) -> f64 {
        self.origin.saturating_duration_since(at).as_secs_f64()
    }

    /// Logs the pointer at `at`. A still pointer gets one sample every half second.
    pub fn sample(&mut self, at: Instant, x: f64, y: f64) {
        let t = self.time(at);
        if let Some(last) = self.samples.last() {
            if (last.x - x).abs() < 1e-5 && (last.y - y).abs() < 1e-5 && t - last.t < 0.5 {
                return;
            }
        }
        self.samples.push(Sample { t, x, y });
    }

    pub fn click(&mut self, at: Instant, x: f64, y: f64) {
        let t = self.time(at);
        self.clicks.push(Sample { t, x, y });
    }

    /// Sets time zero to the moment the first frame was written, re-timing
    /// what was logged before it and dropping what can't be shown.
    pub fn mark_start(&mut self, at: Instant) {
        let shift = self.time(at);
        for s in &mut self.samples { s.t -= shift; }
        for c in &mut self.clicks { c.t -= shift; }
        self.samples.retain(|s| s.t >= -0.05);
        self.clicks.retain(|c| c.t >= 0.0);
        self.origin = at;
        self.started = true;
    }

    pub fn started(&self) -> bool { self.started }
}

/// Double-tap Shift: a tap is a short press of Shift alone (< 0.25 s); two
/// taps starting within 0.35 s of each other fire once. Typing capitals
/// rarely does this, since each Shift there is held across a letter.
///
/// Fed either from a modifier state poll (`poll`, as the Mac does) or from
/// key events (`key`, Windows/evdev hooks); both end up in the same logic.
#[derive(Debug, Default)]
pub struct DoubleShift {
    shift_down_at: Option<f64>,
    last_tap_at: Option<f64>,
    other_since_down: bool,
}

impl DoubleShift {
    /// The modifier state at time `t`: Shift held, other modifiers held.
    /// Returns true when a double tap completes.
    pub fn poll(&mut self, t: f64, shift: bool, others: bool) -> bool {
        if shift && !others {
            if self.shift_down_at.is_none() { self.shift_down_at = Some(t); }
            false
        } else if let Some(down) = self.shift_down_at.take() {
            if others || t - down >= 0.25 {
                self.last_tap_at = None;
                return false;
            }
            match self.last_tap_at {
                Some(last) if down - last < 0.35 => {
                    self.last_tap_at = None;
                    true
                }
                _ => {
                    self.last_tap_at = Some(t);
                    false
                }
            }
        } else {
            false
        }
    }

    /// A key event at time `t`. Any key other than Shift pressed while Shift
    /// is down spoils the tap (Shift+letter is typing, not a tap).
    pub fn key(&mut self, t: f64, key: Key, down: bool) -> bool {
        match key {
            Key::Shift if down => {
                if self.shift_down_at.is_none() { self.other_since_down = false; }
                self.poll(t, true, false)
            }
            Key::Shift => {
                let spoiled = std::mem::take(&mut self.other_since_down);
                self.poll(t, false, spoiled)
            }
            Key::Other if down => {
                if self.shift_down_at.is_some() {
                    self.other_since_down = true;
                } else {
                    // A key between two taps breaks the pair.
                    self.last_tap_at = None;
                }
                false
            }
            Key::Other => false,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Key {
    Shift,
    Other,
}

/// The last moment before `end` that the pointer was outside every bar the
/// user may stop from (the tray's bar, the record pill), so a recording can
/// end before the hand goes there. Generalises the Mac's
/// `lastTimeBelowMenuBar`: each bar is an edge band, its depth a fraction
/// of the content.
pub fn last_time_off_bars(samples: &[Sample], end: f64, bars: &[Bar]) -> Option<f64> {
    samples.iter().rev().filter(|s| s.t <= end).find(|s| !bars.iter().any(|b| b.contains(s.x, s.y))).map(|s| s.t)
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Bar {
    Top(f64),
    Bottom(f64),
    Left(f64),
    Right(f64),
}

impl Bar {
    fn contains(self, x: f64, y: f64) -> bool {
        match self {
            Bar::Top(d) => y <= d,
            Bar::Bottom(d) => y >= 1.0 - d,
            Bar::Left(d) => x <= d,
            Bar::Right(d) => x >= 1.0 - d,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn at(base: Instant, s: f64) -> Instant { base + Duration::from_secs_f64(s) }

    #[test]
    fn still_pointer_is_thinned() {
        let b = Instant::now();
        let mut log = CursorLog::new(b);
        for i in 0..120 { log.sample(at(b, i as f64 / 120.0), 0.5, 0.5); }
        // t = 0 and t = 0.5 (the first sample at least 0.5 s after the last kept one).
        assert_eq!(log.samples.len(), 2);
        log.sample(at(b, 1.0), 0.6, 0.5);
        assert_eq!(log.samples.len(), 3);
    }

    #[test]
    fn mark_start_retimes_and_drops() {
        let b = Instant::now();
        let mut log = CursorLog::new(b);
        log.sample(at(b, 0.0), 0.1, 0.1);
        log.sample(at(b, 0.97), 0.2, 0.2);
        log.click(at(b, 0.5), 0.2, 0.2);
        log.click(at(b, 1.2), 0.3, 0.3);
        log.mark_start(at(b, 1.0));
        assert_eq!(log.samples.len(), 1);
        assert!((log.samples[0].t + 0.03).abs() < 1e-9);
        assert_eq!(log.clicks.len(), 1);
        assert!((log.clicks[0].t - 0.2).abs() < 1e-9);
        log.sample(at(b, 2.0), 0.4, 0.4);
        assert!((log.samples.last().unwrap().t - 1.0).abs() < 1e-9);
    }

    #[test]
    fn samples_before_origin_are_negative() {
        let b = Instant::now() + Duration::from_secs(1);
        let log = CursorLog::new(b);
        assert!((log.time(b - Duration::from_millis(250)) + 0.25).abs() < 1e-9);
    }

    #[test]
    fn double_tap_by_poll() {
        let mut d = DoubleShift::default();
        assert!(!d.poll(0.00, true, false));
        assert!(!d.poll(0.10, false, false));
        assert!(!d.poll(0.20, true, false));
        assert!(d.poll(0.30, false, false));
        // A third tap starts over.
        assert!(!d.poll(0.40, true, false));
        assert!(!d.poll(0.45, false, false));
    }

    #[test]
    fn slow_or_held_taps_dont_fire() {
        let mut d = DoubleShift::default();
        d.poll(0.0, true, false);
        d.poll(0.1, false, false);
        d.poll(0.6, true, false); // 0.6 - 0.1 >= 0.35
        assert!(!d.poll(0.7, false, false));
        let mut d = DoubleShift::default();
        d.poll(0.0, true, false);
        d.poll(0.3, false, false); // held 0.3 s: not a tap
        d.poll(0.4, true, false);
        assert!(!d.poll(0.5, false, false));
        let mut d = DoubleShift::default();
        d.poll(0.0, true, false);
        d.poll(0.1, false, false);
        d.poll(0.2, true, true); // with Cmd/Ctrl/Alt
        assert!(!d.poll(0.3, false, false));
    }

    #[test]
    fn double_tap_by_keys() {
        let mut d = DoubleShift::default();
        d.key(0.00, Key::Shift, true);
        d.key(0.05, Key::Shift, true); // auto-repeat
        d.key(0.10, Key::Shift, false);
        d.key(0.20, Key::Shift, true);
        assert!(d.key(0.30, Key::Shift, false));
    }

    #[test]
    fn typing_capitals_does_not_fire() {
        let mut d = DoubleShift::default();
        d.key(0.00, Key::Shift, true);
        d.key(0.05, Key::Other, true);
        d.key(0.08, Key::Other, false);
        d.key(0.10, Key::Shift, false);
        d.key(0.20, Key::Shift, true);
        d.key(0.24, Key::Other, true);
        assert!(!d.key(0.30, Key::Shift, false));
        // A letter between two clean taps breaks them too.
        let mut d = DoubleShift::default();
        d.key(0.0, Key::Shift, true);
        d.key(0.1, Key::Shift, false);
        d.key(0.15, Key::Other, true);
        d.key(0.2, Key::Shift, true);
        assert!(!d.key(0.3, Key::Shift, false));
    }

    #[test]
    fn bar_trim() {
        let s = |t, y| Sample { t, x: 0.5, y };
        let samples = [s(1.0, 0.5), s(2.0, 0.4), s(3.0, 0.01), s(4.0, 0.0)];
        assert_eq!(last_time_off_bars(&samples, 5.0, &[Bar::Top(0.03)]), Some(2.0));
        assert_eq!(last_time_off_bars(&samples, 5.0, &[Bar::Bottom(0.05)]), Some(4.0));
        assert_eq!(last_time_off_bars(&samples[2..], 5.0, &[Bar::Top(0.03)]), None);
        assert_eq!(last_time_off_bars(&samples, 5.0, &[]), Some(4.0));
    }
}
