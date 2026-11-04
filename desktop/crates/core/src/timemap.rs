//! The video as a sequence of clips, and pure edits to that sequence.

use crate::model::{Clip, EditDoc};
use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Span {
    pub take: i64,
    /// Take time.
    pub start: f64,
    pub end: f64,
    /// Where it begins in output time.
    pub at: f64,
    /// Take seconds per output second.
    pub speed: f64,
    pub fade_in: f64,
    pub fade_out: f64,
}

impl Span {
    /// Footage length, in take time.
    pub fn duration(&self) -> f64 {
        self.end - self.start
    }
    /// How long it plays, in output time.
    pub fn length(&self) -> f64 {
        self.duration() / self.speed
    }
    /// Take time `into` output seconds after the span begins.
    pub fn take_time(&self, into: f64) -> f64 {
        self.start + into * self.speed
    }
}

/// Where output time `t` falls: which clip, which take, and the take time.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Located {
    pub index: usize,
    pub take: i64,
    pub time: f64,
}

/// Output time (player, timeline, export) <-> take and take time (cursor
/// log, zooms, hides).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct TimeMap {
    pub spans: Vec<Span>,
}

impl TimeMap {
    /// Clips in play order (the order is the edit).
    pub fn from_clips(clips: &[Clip]) -> TimeMap {
        let mut at = 0.0;
        let mut spans = Vec::new();
        for c in clips {
            if c.duration() > 1e-3 {
                spans.push(Span {
                    take: c.take,
                    start: c.start,
                    end: c.end,
                    at,
                    speed: c.rate(),
                    fade_in: c.fade_in.max(0.0),
                    fade_out: c.fade_out.max(0.0),
                });
                at += c.output_duration();
            }
        }
        TimeMap { spans }
    }

    pub fn new(doc: &EditDoc, duration: f64) -> TimeMap {
        TimeMap::from_clips(&doc.kept_clips(duration))
    }

    pub fn duration(&self) -> f64 {
        self.spans.last().map_or(0.0, |s| s.at + s.length())
    }

    pub fn locate(&self, t: f64) -> Located {
        let Some(last) = self.spans.last() else { return Located { index: 0, take: 0, time: 0.0 } };
        if t <= 0.0 {
            return Located { index: 0, take: self.spans[0].take, time: self.spans[0].start };
        }
        for (i, s) in self.spans.iter().enumerate() {
            if t < s.at + s.length() {
                return Located { index: i, take: s.take, time: s.take_time(t - s.at).min(s.end) };
            }
        }
        Located { index: self.spans.len() - 1, take: last.take, time: last.end }
    }

    /// Output time of a moment in a take, as it first appears.
    pub fn output(&self, take: i64, time: f64) -> Option<f64> {
        self.spans
            .iter()
            .find(|s| s.take == take && time >= s.start && time <= s.end)
            .map(|s| s.at + (time - s.start) / s.speed)
    }

    pub fn keeps(&self, take: i64, time: f64) -> bool {
        self.output(take, time).is_some()
    }

    /// The same clips at the same speeds (fades may differ).
    pub fn same_timing(&self, o: &TimeMap) -> bool {
        self.spans.len() == o.spans.len()
            && self.spans.iter().zip(&o.spans).all(|(a, b)| {
                a.take == b.take && a.start == b.start && a.end == b.end && a.at == b.at && a.speed == b.speed
            })
    }

    /// How much of the picture shows at output time `t`: 1, or less while a
    /// clip fades up from the backdrop at its start or down at its end.
    pub fn presence(&self, t: f64) -> f64 {
        if self.spans.is_empty() {
            return 1.0;
        }
        let s = &self.spans[self.locate(t).index];
        let (into, left) = (t - s.at, s.at + s.length() - t);
        // A fade never takes more than half its clip.
        let (fi, fo) = (s.fade_in.min(s.length() / 2.0), s.fade_out.min(s.length() / 2.0));
        let smooth = |x: f64| {
            let u = x.clamp(0.0, 1.0);
            u * u * (3.0 - 2.0 * u)
        };
        let mut p = 1.0f64;
        if fi > 1e-3 {
            p = p.min(smooth(into / fi));
        }
        if fo > 1e-3 {
            p = p.min(smooth(left / fo));
        }
        p
    }
}

/// Pure edits to the clip list (split, delete, resize, reorder).
pub mod clip_edits {
    use super::*;

    pub const MIN_LENGTH: f64 = 0.2;

    /// Where each clip starts in output time.
    pub fn starts(clips: &[Clip]) -> Vec<f64> {
        let mut at = 0.0;
        clips
            .iter()
            .map(|c| {
                let s = at;
                at += c.output_duration();
                s
            })
            .collect()
    }

    /// Splits the clip playing at output time `t`; None if too near an edge.
    pub fn split(clips: &[Clip], t: f64) -> Option<Vec<Clip>> {
        let st = starts(clips);
        for (i, c) in clips.iter().enumerate() {
            let into = t - st[i];
            if !(into > 0.0 && into < c.output_duration()) {
                continue;
            }
            if !(into >= MIN_LENGTH / 2.0 && c.output_duration() - into >= MIN_LENGTH / 2.0) {
                return None;
            }
            let mut out = clips.to_vec();
            let cut = c.start + into * c.rate();
            // Both halves keep the speed; the fade in stays at the start, the fade out at the end.
            let mut a = c.clone();
            a.end = cut;
            a.fade_out = 0.0;
            let mut b = c.clone();
            b.start = cut;
            b.fade_in = 0.0;
            out.splice(i..=i, [a, b]);
            return Some(out);
        }
        None
    }

    /// Removes clip `i`; the last clip can't go.
    pub fn delete(clips: &[Clip], i: i64) -> Vec<Clip> {
        let Some(i) = index(clips, i) else { return clips.to_vec() };
        if clips.len() <= 1 {
            return clips.to_vec();
        }
        let mut out = clips.to_vec();
        out.remove(i);
        out
    }

    /// Moves an edge of clip `i` to take time `t`, inside its take and at
    /// least `MIN_LENGTH` long.
    pub fn resize(clips: &[Clip], i: i64, leading: bool, t: f64, take_duration: f64) -> Vec<Clip> {
        let Some(i) = index(clips, i) else { return clips.to_vec() };
        let mut out = clips.to_vec();
        if leading {
            out[i].start = t.max(0.0).min(clips[i].end - MIN_LENGTH);
        } else {
            out[i].end = t.min(take_duration).max(clips[i].start + MIN_LENGTH);
        }
        out
    }

    /// Sets clip `i`'s speed (kept inside the speed range).
    pub fn set_speed(clips: &[Clip], i: i64, speed: f64) -> Vec<Clip> {
        let Some(i) = index(clips, i) else { return clips.to_vec() };
        if !speed.is_finite() {
            return clips.to_vec();
        }
        let mut out = clips.to_vec();
        out[i].speed = speed.clamp(Clip::SPEED_MIN, Clip::SPEED_MAX);
        out
    }

    /// Moves clip `from` so it plays at position `to`.
    pub fn move_clip(clips: &[Clip], from: i64, to: i64) -> Vec<Clip> {
        let Some(from) = index(clips, from) else { return clips.to_vec() };
        let mut out = clips.to_vec();
        let c = out.remove(from);
        let at = to.max(0).min(out.len() as i64) as usize;
        out.insert(at, c);
        out
    }

    /// Where a dragged clip lands: the slot whose midpoint its centre passed.
    pub fn drop_index(clips: &[Clip], dragging: i64, centre_at: f64) -> i64 {
        let Some(i) = index(clips, dragging) else { return dragging };
        let mut others = clips.to_vec();
        others.remove(i);
        let st = starts(&others);
        for (k, c) in others.iter().enumerate() {
            if centre_at < st[k] + c.output_duration() / 2.0 {
                return k as i64;
            }
        }
        others.len() as i64
    }

    fn index(clips: &[Clip], i: i64) -> Option<usize> {
        usize::try_from(i).ok().filter(|&i| i < clips.len())
    }
}
