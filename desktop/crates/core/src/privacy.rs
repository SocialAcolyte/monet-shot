//! Hide (blur / pixelate / cover) and crop, in a take's normalised picture.

use crate::model::{new_id, string_enum, swift_int, upper_id, Extra};
use serde::{Deserialize, Serialize};
use serde_json::Map;

/// A rectangle in a take's picture: (0,0) top-left, (1,1) bottom-right.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct NormRect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl NormRect {
    pub const FULL: NormRect = NormRect { x: 0.0, y: 0.0, w: 1.0, h: 1.0 };

    pub fn new(x: f64, y: f64, w: f64, h: f64) -> Self {
        NormRect { x, y, w, h }
    }
    pub fn is_full(&self) -> bool {
        self.x <= 1e-4 && self.y <= 1e-4 && self.w >= 1.0 - 1e-4 && self.h >= 1.0 - 1e-4
    }
    pub fn max_x(&self) -> f64 {
        self.x + self.w
    }
    pub fn max_y(&self) -> f64 {
        self.y + self.h
    }

    /// Kept inside the frame and at least `min_size` across.
    pub fn clamped(&self, min_size: f64) -> NormRect {
        let w = self.w.max(min_size).min(1.0);
        let h = self.h.max(min_size).min(1.0);
        NormRect { x: self.x.max(0.0).min(1.0 - w), y: self.y.max(0.0).min(1.0 - h), w, h }
    }

    /// The rectangle spanned by two corners, in either order.
    pub fn spanning(a: (f64, f64), b: (f64, f64)) -> NormRect {
        NormRect { x: a.0.min(b.0), y: a.1.min(b.1), w: (a.0 - b.0).abs(), h: (a.1 - b.1).abs() }
    }

    /// A point of the whole frame in this rectangle's own 0...1 coordinates.
    pub fn local(&self, px: f64, py: f64) -> (f64, f64) {
        ((px - self.x) / self.w.max(1e-6), (py - self.y) / self.h.max(1e-6))
    }

    /// A point in this rectangle's own coordinates, back in the whole frame.
    pub fn global(&self, u: f64, v: f64) -> (f64, f64) {
        (self.x + u * self.w, self.y + v * self.h)
    }

    /// Slid by (dx, dy), stopping at the frame's edges.
    pub fn moved(&self, dx: f64, dy: f64) -> NormRect {
        NormRect {
            x: (self.x + dx).max(0.0).min(1.0 - self.w),
            y: (self.y + dy).max(0.0).min(1.0 - self.h),
            w: self.w,
            h: self.h,
        }
    }

    /// Resized by dragging one handle: 0 = left/top edge, 1 = right/bottom,
    /// 0.5 = that axis doesn't change. The opposite edges stay put.
    pub fn resized(&self, hx: f64, hy: f64, dx: f64, dy: f64, m: f64) -> NormRect {
        let (mut x0, mut x1, mut y0, mut y1) = (self.x, self.max_x(), self.y, self.max_y());
        if hx < 0.25 {
            x0 = (x0 + dx).max(0.0).min(x1 - m)
        } else if hx > 0.75 {
            x1 = (x1 + dx).min(1.0).max(x0 + m)
        }
        if hy < 0.25 {
            y0 = (y0 + dy).max(0.0).min(y1 - m)
        } else if hy > 0.75 {
            y1 = (y1 + dy).min(1.0).max(y0 + m)
        }
        NormRect { x: x0, y: y0, w: x1 - x0, h: y1 - y0 }
    }
}

string_enum!(
    /// How a hidden part looks.
    BlurStyle, default Blur, { Blur = "blur", Pixelate = "pixelate", Solid = "solid" }
);

impl BlurStyle {
    pub fn label(&self) -> &str {
        match self.known() {
            BlurStyle::Pixelate => "Pixelate",
            BlurStyle::Solid => "Cover",
            _ => "Blur",
        }
    }
}

/// A part of the recording hidden in the video, on the footage (take and
/// take time), drawn into the raw frame before any framing or zoom.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BlurRegion {
    #[serde(deserialize_with = "upper_id")]
    pub id: String,
    #[serde(deserialize_with = "swift_int")]
    pub take: i64,
    pub rect: NormRect,
    pub style: BlurStyle,
    /// 0 = light, 1 = heavy.
    pub strength: f64,
    /// Take time it appears and goes; None = from the start / to the end.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end: Option<f64>,
    #[serde(flatten, default, skip_serializing_if = "Map::is_empty")]
    pub extra: Extra,
}

impl BlurRegion {
    pub fn new(take: i64, rect: NormRect, style: BlurStyle, strength: f64, start: Option<f64>, end: Option<f64>) -> Self {
        BlurRegion { id: new_id(), take, rect, style, strength, start, end, extra: Extra::new() }
    }
    pub fn always(&self) -> bool {
        self.start.is_none() && self.end.is_none()
    }
    pub fn covers(&self, t: f64) -> bool {
        self.start.map_or(true, |s| t >= s) && self.end.map_or(true, |e| t < e)
    }
}

/// The part of a take that makes the picture.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TakeCrop {
    #[serde(deserialize_with = "swift_int")]
    pub take: i64,
    pub rect: NormRect,
    #[serde(flatten, default, skip_serializing_if = "Map::is_empty")]
    pub extra: Extra,
}

impl TakeCrop {
    pub fn new(take: i64, rect: NormRect) -> Self {
        TakeCrop { take, rect, extra: Extra::new() }
    }
}
