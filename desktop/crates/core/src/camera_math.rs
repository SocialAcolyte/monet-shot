//! The virtual camera: the smoothed pointer, zooms made from clicks, the
//! camera at any moment, click ripples and the press dip.

use crate::model::{CursorSample, ZoomSegment};
use serde::Serialize;

/// A pointer path resampled at 120 Hz and smoothed, read identically by the
/// preview and the export.
#[derive(Debug, Clone, PartialEq)]
pub struct SmoothTrack {
    pub xs: Vec<f64>,
    pub ys: Vec<f64>,
}

impl SmoothTrack {
    pub const RATE: f64 = 120.0;

    /// Position at time `t`, linearly between samples, clamped to the ends.
    pub fn position(&self, t: f64) -> (f64, f64) {
        if self.xs.is_empty() {
            return (0.5, 0.5);
        }
        let f = (t * Self::RATE).max(0.0);
        // Swift's Int(f) truncates (and f >= 0 here).
        let i = (f as usize).min(self.xs.len() - 1);
        let j = (i + 1).min(self.xs.len() - 1);
        let a = f - i as f64;
        (self.xs[i] + (self.xs[j] - self.xs[i]) * a, self.ys[i] + (self.ys[j] - self.ys[i]) * a)
    }

    /// Resamples over [0, duration] and runs a critically damped spring
    /// forwards then backwards, which cancels the lag of a one-way filter.
    pub fn make(samples: &[CursorSample], duration: f64, omega: f64) -> SmoothTrack {
        let n = 2usize.max(((duration * Self::RATE).ceil() as i64 + 1).max(0) as usize);
        let Some(first) = samples.first() else {
            return SmoothTrack { xs: vec![0.5; n], ys: vec![0.5; n] };
        };
        let mut raw_x = vec![first.x; n];
        let mut raw_y = vec![first.y; n];
        let mut k = 0usize;
        for i in 0..n {
            let t = i as f64 / Self::RATE;
            while k + 1 < samples.len() && samples[k + 1].t <= t {
                k += 1;
            }
            let a = samples[k];
            if k + 1 < samples.len() && t > a.t {
                let b = samples[k + 1];
                let u = (t - a.t) / (b.t - a.t).max(1e-6);
                raw_x[i] = a.x + (b.x - a.x) * u;
                raw_y[i] = a.y + (b.y - a.y) * u;
            } else {
                raw_x[i] = a.x;
                raw_y[i] = a.y;
            }
        }
        let pad = Self::RATE as usize;
        let smoothed = |raw: &[f64]| -> Vec<f64> {
            let mut padded = vec![raw[0]; pad];
            padded.extend_from_slice(raw);
            padded.extend(std::iter::repeat(raw[raw.len() - 1]).take(pad));
            let mut fwd = spring(&padded, omega);
            fwd.reverse();
            let mut both = spring(&fwd, omega);
            both.reverse();
            both[pad..pad + raw.len()].to_vec()
        };
        SmoothTrack { xs: smoothed(&raw_x), ys: smoothed(&raw_y) }
    }
}

/// One pass of a critically damped spring chasing `target`, at 120 Hz.
pub fn spring(target: &[f64], omega: f64) -> Vec<f64> {
    let Some(&first) = target.first() else { return vec![] };
    let mut x = first;
    let mut v = 0.0;
    let dt = 1.0 / SmoothTrack::RATE;
    let steps = 1i64.max((omega * dt / 0.25).ceil() as i64);
    let h = dt / steps as f64;
    let mut out = Vec::with_capacity(target.len());
    for &goal in target {
        for _ in 0..steps {
            v += (omega * omega * (goal - x) - 2.0 * omega * v) * h;
            x += v * h;
        }
        out.push(x);
    }
    out
}

/// Where the virtual camera looks: zoom and centre, normalised content
/// coordinates (top-left origin).
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Camera {
    pub scale: f64,
    pub center_x: f64,
    pub center_y: f64,
}

impl Camera {
    pub const IDENTITY: Camera = Camera { scale: 1.0, center_x: 0.5, center_y: 0.5 };

    /// The visible part of the content: (x, y, w, h), normalised.
    pub fn viewport(&self) -> (f64, f64, f64, f64) {
        let w = 1.0 / self.scale;
        let h = 1.0 / self.scale;
        (self.center_x - w / 2.0, self.center_y - h / 2.0, w, h)
    }

    /// A content point in viewport coordinates (0...1 across the frame).
    pub fn project(&self, x: f64, y: f64) -> (f64, f64) {
        let (vx, vy, vw, vh) = self.viewport();
        ((x - vx) / vw, (y - vy) / vh)
    }
}

/// Seconds the camera takes to zoom in, and again to zoom out.
pub const RAMP: f64 = 0.75;
/// Clicks closer together than this become one zoom.
pub const CLUSTER_GAP: f64 = 2.6;
pub const LEAD_IN: f64 = 0.9;
pub const HOLD_AFTER: f64 = 1.7;
pub const DEFAULT_SCALE: f64 = 2.0;
/// Zooms closer than this merge into one that pans between them.
pub const MERGE_GAP: f64 = 2.5;
/// The camera follows a much lazier copy of the cursor.
pub const CAMERA_OMEGA: f64 = 3.2;

/// Spring stiffness for the visible cursor from the 0...1 smoothing.
pub fn cursor_omega(smoothing: f64) -> f64 {
    let s = smoothing.max(0.0).min(1.0);
    60.0 * (8.0f64 / 60.0).powf(s)
}

/// Zooms made from clicks (defaults: `DEFAULT_SCALE`, take 0).
pub fn auto_zooms(clicks: &[CursorSample], duration: f64) -> Vec<ZoomSegment> {
    auto_zooms_with(clicks, duration, DEFAULT_SCALE, 0)
}

pub fn auto_zooms_with(clicks: &[CursorSample], duration: f64, scale: f64, take: i64) -> Vec<ZoomSegment> {
    let mut sorted: Vec<CursorSample> = clicks.iter().copied().filter(|c| c.t >= 0.0 && c.t <= duration).collect();
    sorted.sort_by(|a, b| a.t.total_cmp(&b.t));
    if sorted.is_empty() {
        return vec![];
    }
    let mut groups: Vec<Vec<CursorSample>> = vec![vec![sorted[0]]];
    for c in &sorted[1..] {
        let last = groups.last().unwrap().last().unwrap().t;
        if c.t - last < CLUSTER_GAP {
            groups.last_mut().unwrap().push(*c);
        } else {
            groups.push(vec![*c]);
        }
    }
    let mut spans: Vec<(f64, f64)> = groups
        .iter()
        .map(|g| ((g[0].t - LEAD_IN).max(0.0), (g[g.len() - 1].t + HOLD_AFTER).min(duration)))
        .collect();
    spans.sort_by(|a, b| a.0.total_cmp(&b.0));
    let mut merged: Vec<(f64, f64)> = vec![];
    for s in spans {
        if let Some(last) = merged.last_mut() {
            if s.0 - last.1 < MERGE_GAP {
                last.1 = last.1.max(s.1);
                continue;
            }
        }
        merged.push(s);
    }
    merged
        .into_iter()
        .filter(|s| s.1 - s.0 >= RAMP)
        .map(|s| ZoomSegment::new(s.0, s.1, scale, true, take))
        .collect()
}

/// 0 outside the segment, rising to 1 over `RAMP`, holding, falling at its end.
pub fn weight(s: &ZoomSegment, t: f64) -> f64 {
    if !(t > s.start && t < s.end) {
        return 0.0;
    }
    let r = RAMP.min(s.duration() / 2.0);
    if !(r > 0.0) {
        return 0.0;
    }
    let up = (t - s.start) / r;
    let down = (s.end - t) / r;
    ease(1f64.min(up.min(down)))
}

/// Smootherstep.
pub fn ease(u: f64) -> f64 {
    let x = u.max(0.0).min(1.0);
    x * x * x * (x * (x * 6.0 - 15.0) + 10.0)
}

/// The camera at time `t`: the strongest segment wins; the centre is the
/// focus clamped so the view never leaves the recording.
pub fn camera_at(t: f64, segments: &[ZoomSegment], focus: &SmoothTrack) -> Camera {
    let mut best: Option<(&ZoomSegment, f64)> = None;
    for s in segments {
        let w = weight(s, t);
        if w > 0.0 && w > best.map_or(0.0, |b| b.1) {
            best = Some((s, w));
        }
    }
    let Some((seg, w)) = best else { return Camera::IDENTITY };
    let scale = 1.0 + (seg.scale.max(1.0) - 1.0) * w;
    let f = if seg.follows_cursor() { focus.position(t) } else { (seg.focus_x.unwrap(), seg.focus_y.unwrap()) };
    let half = 0.5 / scale;
    Camera { scale, center_x: f.0.max(half).min(1.0 - half), center_y: f.1.max(half).min(1.0 - half) }
}

pub const RIPPLE_DURATION: f64 = 0.55;

/// Recent clicks and how far through its ripple each is (0 new, 1 gone).
pub fn ripples(clicks: &[CursorSample], t: f64, duration: f64) -> Vec<(CursorSample, f64)> {
    clicks
        .iter()
        .filter_map(|c| {
            let age = t - c.t;
            (age >= 0.0 && age < duration).then(|| (*c, age / duration))
        })
        .collect()
}

/// The cursor dips to this scale for a moment on each click.
pub fn press_scale(clicks: &[CursorSample], t: f64) -> f64 {
    let mut s = 1.0f64;
    for c in clicks {
        let age = t - c.t;
        if age >= -0.04 && age < 0.22 {
            let u = age.max(0.0) / 0.22;
            s = s.min(1.0 - 0.18 * (std::f64::consts::PI * (u + 0.18).min(1.0)).sin());
        }
    }
    s
}

/// Pure edits to the zoom list.
pub mod segment_edits {
    use super::*;

    pub const MIN_DURATION: f64 = 0.4;

    /// Moves a segment by `delta`, kept inside [0, duration]; it becomes hand-made.
    pub fn move_by(s: &ZoomSegment, delta: f64, duration: f64) -> ZoomSegment {
        let mut out = s.clone();
        let d = delta.max(-s.start).min(duration - s.end);
        out.start += d;
        out.end += d;
        out.auto = false;
        out
    }

    pub fn resize(s: &ZoomSegment, leading: bool, time: f64, duration: f64) -> ZoomSegment {
        let mut out = s.clone();
        if leading {
            out.start = time.max(0.0).min(s.end - MIN_DURATION);
        } else {
            out.end = time.min(duration).max(s.start + MIN_DURATION);
        }
        out.auto = false;
        out
    }

    /// A new hand-made zoom centred on `time` in take `take`, fitted to the
    /// free space; None if there is no room.
    pub fn insert(time: f64, segments: &[ZoomSegment], duration: f64, length: f64, take: i64) -> Option<ZoomSegment> {
        let (mut lo, mut hi) = (0.0f64, duration);
        for s in segments.iter().filter(|s| s.take == take) {
            if s.start <= time && time <= s.end {
                return None;
            }
            if s.end <= time {
                lo = lo.max(s.end);
            }
            if s.start >= time {
                hi = hi.min(s.start);
            }
        }
        let start = lo.max(time - length / 2.0);
        let end = hi.min(start + length);
        if end - start < MIN_DURATION {
            return None;
        }
        Some(ZoomSegment::new(start, end, DEFAULT_SCALE, false, take))
    }

    /// Re-runs auto-zoom on one take: hand-made zooms stay; auto ones are
    /// replaced, except where a new one would overlap a hand-made one.
    pub fn re_auto(segments: &[ZoomSegment], clicks: &[CursorSample], duration: f64, take: i64) -> Vec<ZoomSegment> {
        let others: Vec<ZoomSegment> = segments.iter().filter(|s| s.take != take).cloned().collect();
        let manual: Vec<ZoomSegment> = segments.iter().filter(|s| !s.auto && s.take == take).cloned().collect();
        let fresh: Vec<ZoomSegment> = auto_zooms_with(clicks, duration, DEFAULT_SCALE, take)
            .into_iter()
            .filter(|a| !manual.iter().any(|m| a.start < m.end && m.start < a.end))
            .collect();
        let mut mine: Vec<ZoomSegment> = manual.into_iter().chain(fresh).collect();
        mine.sort_by(|a, b| a.start.total_cmp(&b.start));
        others.into_iter().chain(mine).collect()
    }
}
