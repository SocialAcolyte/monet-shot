//! The video as a sequence of clips, and pure edits to that sequence.

use crate::model::{Clip, EditDoc};
use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Span {
    pub take: i64,
    /// Take time.
    pub start: f64,
    pub end: f64,
    /// Where it begins in output time.
    pub at: f64,
}

impl Span {
    pub fn duration(&self) -> f64 {
        self.end - self.start
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
                spans.push(Span { take: c.take, start: c.start, end: c.end, at });
                at += c.duration();
            }
        }
        TimeMap { spans }
    }

    pub fn new(doc: &EditDoc, duration: f64) -> TimeMap {
        TimeMap::from_clips(&doc.kept_clips(duration))
    }

    pub fn duration(&self) -> f64 {
        self.spans.last().map_or(0.0, |s| s.at + s.duration())
    }

    pub fn locate(&self, t: f64) -> Located {
        let Some(last) = self.spans.last() else { return Located { index: 0, take: 0, time: 0.0 } };
        if t <= 0.0 {
            return Located { index: 0, take: self.spans[0].take, time: self.spans[0].start };
        }
        for (i, s) in self.spans.iter().enumerate() {
            if t < s.at + s.duration() {
                return Located { index: i, take: s.take, time: s.start + (t - s.at) };
            }
        }
        Located { index: self.spans.len() - 1, take: last.take, time: last.end }
    }

    /// Output time of a moment in a take, as it first appears.
    pub fn output(&self, take: i64, time: f64) -> Option<f64> {
        self.spans
            .iter()
            .find(|s| s.take == take && time >= s.start && time <= s.end)
            .map(|s| s.at + (time - s.start))
    }

    pub fn keeps(&self, take: i64, time: f64) -> bool {
        self.output(take, time).is_some()
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
                at += c.duration();
                s
            })
            .collect()
    }

    /// Splits the clip playing at output time `t`; None if too near an edge.
    pub fn split(clips: &[Clip], t: f64) -> Option<Vec<Clip>> {
        let st = starts(clips);
        for (i, c) in clips.iter().enumerate() {
            let into = t - st[i];
            if !(into > 0.0 && into < c.duration()) {
                continue;
            }
            if !(into >= MIN_LENGTH / 2.0 && c.duration() - into >= MIN_LENGTH / 2.0) {
                return None;
            }
            let mut out = clips.to_vec();
            let cut = c.start + into;
            let mut a = c.clone();
            a.end = cut;
            let mut b = c.clone();
            b.start = cut;
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
            if centre_at < st[k] + c.duration() / 2.0 {
                return k as i64;
            }
        }
        others.len() as i64
    }

    fn index(clips: &[Clip], i: i64) -> Option<usize> {
        usize::try_from(i).ok().filter(|&i| i < clips.len())
    }
}
