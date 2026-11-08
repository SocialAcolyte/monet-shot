//! Vertical and square videos: the canvas layouts, the phone's safe area,
//! and follow framing (a tall window that pans with the action). A port of
//! `Sources/MonetShotKit/Core/Vertical.swift`; `shared/fixtures/vertical.json`
//! keeps the two in step.

use crate::camera_math::{self, spring, Camera, SmoothTrack};
use crate::model::{string_enum, EditDoc, ZoomSegment};
use crate::plan::Rect;

string_enum!(
    /// The shape a video is made for (`EditDoc.layout`; none = landscape,
    /// the edit's own `output_width` x `canvas_aspect`, left untouched).
    CanvasLayout, default Landscape, { Landscape = "landscape", Vertical = "vertical", Square = "square" }
);

impl CanvasLayout {
    pub fn label(&self) -> &str {
        match self.known() {
            CanvasLayout::Vertical => "Vertical",
            CanvasLayout::Square => "Square",
            _ => "Landscape",
        }
    }

    /// The canvas in pixels; None for landscape (the edit's own size).
    pub fn size(&self) -> Option<(i64, i64)> {
        match self.known() {
            CanvasLayout::Vertical => Some((1080, 1920)),
            CanvasLayout::Square => Some((1080, 1080)),
            _ => None,
        }
    }
}

impl EditDoc {
    pub fn canvas_layout(&self) -> CanvasLayout {
        self.layout.as_ref().map_or(CanvasLayout::Landscape, |l| l.known())
    }

    /// Sets the layout; landscape removes the key, so the edit is what it was.
    pub fn set_layout(&mut self, l: CanvasLayout) {
        self.layout = (l.known() != CanvasLayout::Landscape).then_some(l);
    }

    /// A wide take is cropped to a window that follows the action.
    pub fn follows_action(&self) -> bool {
        self.canvas_layout() != CanvasLayout::Landscape
    }
}

pub const SAFE_TOP: f64 = 0.12;
pub const SAFE_BOTTOM: f64 = 0.20;
pub const SAFE_SIDE: f64 = 0.08;
/// The bottom of the safe area kept for captions (a fraction of the canvas
/// height): the vertical camera bubble sits above it.
pub const CAPTION_BAND: f64 = 0.10;

/// Whether a canvas is tall enough for phone apps to cover its edges.
pub fn safe_area_is_inset(canvas_width: f64, canvas_height: f64) -> bool {
    canvas_height > canvas_width * 1.25
}

/// The part of a canvas (pixels, top-left origin) that phone apps leave
/// clear: on a tall canvas Reels, Shorts and TikTok cover the top ~12% and
/// bottom ~20% with their own buttons and words, and the sides a little.
/// Any other canvas is clear edge to edge. Texts and captions go inside it.
pub fn safe_area(canvas_width: f64, canvas_height: f64) -> Rect {
    if !safe_area_is_inset(canvas_width, canvas_height) {
        return Rect::new(0.0, 0.0, canvas_width, canvas_height);
    }
    let side = (canvas_width * SAFE_SIDE).round();
    let top = (canvas_height * SAFE_TOP).round();
    let bottom = (canvas_height * SAFE_BOTTOM).round();
    Rect::new(side, top, canvas_width - 2.0 * side, canvas_height - top - bottom)
}

/// The share of a zoom's depth kept in a follow window (2x becomes 1.6x).
pub const ZOOM_DEPTH: f64 = 0.6;
/// How far the action may stray from the window's centre before it moves,
/// as a fraction of the window's width (or height).
pub const DEAD_ZONE: f64 = 0.22;
/// The glide's stiffness, rad/s.
pub const OMEGA: f64 = 2.4;

/// The window's shape (normalised width over height) for a take of
/// `take_aspect` in a frame of `frame_aspect`; None when the take is no
/// wider than the frame, which then shows it whole.
pub fn window(take_aspect: f64, frame_aspect: f64) -> Option<f64> {
    (frame_aspect > 0.0 && take_aspect > frame_aspect * 1.001).then(|| frame_aspect / take_aspect)
}

fn strongest(t: f64, segments: &[ZoomSegment]) -> Option<(&ZoomSegment, f64)> {
    let mut best: Option<(&ZoomSegment, f64)> = None;
    for s in segments {
        let w = camera_math::weight(s, t);
        if w > 0.0 && w > best.map_or(0.0, |b| b.1) {
            best = Some((s, w));
        }
    }
    best
}

/// The follow window's zoom at take time `t`.
pub fn scale(t: f64, segments: &[ZoomSegment]) -> f64 {
    match strongest(t, segments) {
        Some((seg, w)) => 1.0 + (seg.scale.max(1.0) - 1.0) * ZOOM_DEPTH * w,
        None => 1.0,
    }
}

/// One take's follow path: the window's centre over the take's time (its
/// cropped picture's 0...1 coordinates), at 120 Hz. It holds still while the
/// action stays near the middle, then glides to it (a critically damped
/// spring run both ways: no lag, no drift). The action is the zoom's target
/// while a zoom holds on a point, otherwise the camera copy of the pointer.
#[derive(Debug, Clone, PartialEq)]
pub struct FollowTrack {
    pub window: f64,
    pub path: SmoothTrack,
}

impl FollowTrack {
    /// `focus` is the take's camera copy of the pointer (`CAMERA_OMEGA`).
    pub fn make(window: f64, segments: &[ZoomSegment], focus: &SmoothTrack, duration: f64) -> FollowTrack {
        let rate = SmoothTrack::RATE;
        let n = 2usize.max(((duration * rate).ceil() as i64 + 1).max(0) as usize);
        let mut gx = vec![0.5; n];
        let mut gy = vec![0.5; n];
        let (mut x, mut y) = (0.5, 0.5);
        for i in 0..n {
            let t = i as f64 / rate;
            let best = strongest(t, segments);
            let s = best.map_or(1.0, |(seg, w)| 1.0 + (seg.scale.max(1.0) - 1.0) * ZOOM_DEPTH * w);
            let mut target = focus.position(t);
            if let Some((seg, _)) = best {
                if let (Some(fx), Some(fy)) = (seg.focus_x, seg.focus_y) {
                    target = (fx, fy);
                }
            }
            let (w, h) = (window / s, 1.0 / s);
            // Hold still until the action leaves the dead zone, then aim at it.
            if i == 0 || (target.0 - x).abs() > DEAD_ZONE * w {
                x = target.0;
            }
            if i == 0 || (target.1 - y).abs() > DEAD_ZONE * h {
                y = target.1;
            }
            x = x.max(w / 2.0).min(1.0 - w / 2.0);
            y = y.max(h / 2.0).min(1.0 - h / 2.0);
            gx[i] = x;
            gy[i] = y;
        }
        FollowTrack { window, path: SmoothTrack { xs: glide(&gx), ys: glide(&gy) } }
    }

    /// The camera at take time `t`: the glide's centre, kept inside the
    /// picture at that moment's zoom.
    pub fn camera(&self, t: f64, segments: &[ZoomSegment]) -> Camera {
        let s = scale(t, segments);
        let p = self.path.position(t);
        let (w, h) = (self.window / s, 1.0 / s);
        Camera {
            scale: s,
            center_x: p.0.max(w / 2.0).min(1.0 - w / 2.0),
            center_y: p.1.max(h / 2.0).min(1.0 - h / 2.0),
            window: self.window,
        }
    }
}

/// The aims smoothed by the spring forwards then backwards, with a second
/// of the first and last aim either side so both passes settle.
fn glide(aims: &[f64]) -> Vec<f64> {
    let pad = SmoothTrack::RATE as usize;
    let mut padded = vec![aims[0]; pad];
    padded.extend_from_slice(aims);
    padded.extend(std::iter::repeat(aims[aims.len() - 1]).take(pad));
    let mut fwd = spring(&padded, OMEGA);
    fwd.reverse();
    let mut both = spring(&fwd, OMEGA);
    both.reverse();
    both[pad..pad + aims.len()].to_vec()
}
