//! The `.reel` files: meta.json, cursor.json, edit.json. Field names, defaults
//! and which keys are required match the Swift `Codable` types exactly
//! (`Sources/MonetShotKit/Model`). Keys this version doesn't know are kept in
//! `extra` and written back, so a newer Mac's edit survives a trip through
//! the desktop app. Enum values it doesn't know are kept too.

use crate::json::IsoDate;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

pub type Extra = Map<String, Value>;

/// A fresh id as the Mac writes them (`UUID().uuidString`: upper case).
pub fn new_id() -> String {
    uuid::Uuid::new_v4().to_string().to_uppercase()
}

/// An Int as Swift's decoder reads one: `1920` or `1920.0` (a whole number).
pub(crate) fn swift_int<'de, D: serde::Deserializer<'de>>(d: D) -> Result<i64, D::Error> {
    let v = f64_or_i64(d)?;
    v.ok_or_else(|| serde::de::Error::custom("not a whole number"))
}

pub(crate) fn swift_int_opt<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<i64>, D::Error> {
    let v: Option<serde_json::Number> = Option::deserialize(d)?;
    match v {
        None => Ok(None),
        Some(n) => number_to_int(&n).map(Some).ok_or_else(|| serde::de::Error::custom("not a whole number")),
    }
}

fn number_to_int(n: &serde_json::Number) -> Option<i64> {
    n.as_i64().or_else(|| n.as_f64().filter(|f| f.fract() == 0.0 && f.abs() < 9.2e18).map(|f| f as i64))
}

fn f64_or_i64<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<i64>, D::Error> {
    let n = serde_json::Number::deserialize(d)?;
    Ok(number_to_int(&n))
}

pub(crate) fn upper_id<'de, D: serde::Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    let s = String::deserialize(d)?;
    uuid::Uuid::parse_str(&s).map_err(serde::de::Error::custom)?;
    Ok(s.to_uppercase())
}

/// A string enum that keeps values it doesn't know (`Other`), drawing them
/// as its default.
macro_rules! string_enum {
    ($(#[$m:meta])* $name:ident, default $def:ident, { $($(#[$vm:meta])* $var:ident = $s:literal),* $(,)? }) => {
        $(#[$m])*
        #[derive(Debug, Clone, PartialEq, Eq, Hash)]
        pub enum $name { $($(#[$vm])* $var,)* Other(String) }

        impl $name {
            pub const ALL: &'static [$name] = &[$($name::$var),*];
            pub fn as_str(&self) -> &str {
                match self { $($name::$var => $s,)* $name::Other(s) => s.as_str() }
            }
            pub fn parse(s: &str) -> $name {
                match s { $($s => $name::$var,)* other => $name::Other(other.to_string()) }
            }
            /// What this value draws as (`Other` draws as the default).
            pub fn known(&self) -> $name {
                match self { $name::Other(_) => $name::$def, v => v.clone() }
            }
        }
        impl Default for $name { fn default() -> Self { $name::$def } }
        impl serde::Serialize for $name {
            fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> { s.serialize_str(self.as_str()) }
        }
        impl<'de> serde::Deserialize<'de> for $name {
            fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
                Ok($name::parse(&<String as serde::Deserialize>::deserialize(d)?))
            }
        }
    };
}
pub(crate) use string_enum;

/// Pointer position, normalised to the captured content: (0,0) top-left of
/// the video frame, (1,1) bottom-right.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct CursorSample {
    pub t: f64,
    pub x: f64,
    pub y: f64,
}

impl CursorSample {
    pub fn new(t: f64, x: f64, y: f64) -> Self {
        CursorSample { t, x, y }
    }
}

/// cursor.json. Both lists are required, as on the Mac.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct CursorTrack {
    pub samples: Vec<CursorSample>,
    /// Mouse-down moments, same coordinates as `samples`.
    pub clicks: Vec<CursorSample>,
    #[serde(flatten, default, skip_serializing_if = "Map::is_empty")]
    pub extra: Extra,
}

fn default_video() -> String {
    "screen.mov".into()
}

/// meta.json.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordingMeta {
    #[serde(deserialize_with = "swift_int")]
    pub pixel_width: i64,
    #[serde(deserialize_with = "swift_int")]
    pub pixel_height: i64,
    /// Backing scale of the captured content (2 on a Retina display).
    pub point_scale: f64,
    pub duration: f64,
    pub created_at: IsoDate,
    /// "display", "window", or "import".
    pub source: String,
    /// The take's video file name, inside its folder.
    #[serde(default = "default_video")]
    pub video: String,
    /// You on camera, recorded with this take (file name).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub camera: Option<String>,
    /// Take time at which the camera file starts.
    #[serde(default)]
    pub camera_offset: f64,
    #[serde(flatten, default, skip_serializing_if = "Map::is_empty")]
    pub extra: Extra,
}

impl RecordingMeta {
    pub fn new(pixel_width: i64, pixel_height: i64, point_scale: f64, duration: f64, created_at: IsoDate, source: &str, video: &str) -> Self {
        RecordingMeta {
            pixel_width,
            pixel_height,
            point_scale,
            duration,
            created_at,
            source: source.into(),
            video: video.into(),
            camera: None,
            camera_offset: 0.0,
            extra: Extra::new(),
        }
    }

    pub fn aspect(&self) -> f64 {
        self.pixel_width as f64 / self.pixel_height.max(1) as f64
    }
}

/// One zoom on the timeline, in its take's own time.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ZoomSegment {
    #[serde(deserialize_with = "upper_id")]
    pub id: String,
    pub start: f64,
    pub end: f64,
    pub scale: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub focus_x: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub focus_y: Option<f64>,
    /// Made by auto-zoom (replaced when it re-runs) or by hand.
    #[serde(default)]
    pub auto: bool,
    #[serde(default, deserialize_with = "swift_int")]
    pub take: i64,
    #[serde(flatten, default, skip_serializing_if = "Map::is_empty")]
    pub extra: Extra,
}

impl ZoomSegment {
    pub fn new(start: f64, end: f64, scale: f64, auto: bool, take: i64) -> Self {
        ZoomSegment { id: new_id(), start, end, scale, focus_x: None, focus_y: None, auto, take, extra: Extra::new() }
    }
    pub fn duration(&self) -> f64 {
        self.end - self.start
    }
    pub fn follows_cursor(&self) -> bool {
        self.focus_x.is_none() || self.focus_y.is_none()
    }
}

string_enum!(
    /// The surface the recording sits on.
    Backdrop, default Paper, {
        Paper = "paper", Charcoal = "charcoal", Dusk = "dusk", Slate = "slate",
        /// No frame: the recording fills the canvas edge to edge.
        None = "none",
        /// A picture (`EditDoc.backdrop_image`) filling the canvas.
        Image = "image",
    }
);

impl Backdrop {
    pub fn label(&self) -> &str {
        match self.known() {
            Backdrop::Paper => "Paper",
            Backdrop::Charcoal => "Charcoal",
            Backdrop::Dusk => "Dusk",
            Backdrop::Slate => "Slate",
            Backdrop::None => "None",
            _ => "Image",
        }
    }
}

fn one() -> f64 {
    1.0
}
fn is_one(v: &f64) -> bool {
    *v == 1.0
}
fn is_zero(v: &f64) -> bool {
    *v == 0.0
}

/// A stretch of one take, in that take's own time.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Clip {
    pub start: f64,
    pub end: f64,
    #[serde(default, deserialize_with = "swift_int")]
    pub take: i64,
    /// How fast the footage plays: 2 is twice as fast, 0.5 slow motion.
    /// Written only when set, as on the Mac.
    #[serde(default = "one", skip_serializing_if = "is_one")]
    pub speed: f64,
    /// Seconds (output time) over which the clip fades up from the backdrop
    /// at its start, and down at its end. 0 = a straight cut.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub fade_in: f64,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub fade_out: f64,
    #[serde(flatten, default, skip_serializing_if = "Map::is_empty")]
    pub extra: Extra,
}

impl Clip {
    pub const SPEEDS: [f64; 9] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0];
    pub const SPEED_MIN: f64 = 0.25;
    pub const SPEED_MAX: f64 = 4.0;

    pub fn new(start: f64, end: f64, take: i64) -> Self {
        Clip { start, end, take, speed: 1.0, fade_in: 0.0, fade_out: 0.0, extra: Extra::new() }
    }
    /// Length of footage, in take time.
    pub fn duration(&self) -> f64 {
        self.end - self.start
    }
    /// The speed actually used (kept inside SPEED_MIN...SPEED_MAX).
    pub fn rate(&self) -> f64 {
        if self.speed.is_finite() { self.speed.clamp(Clip::SPEED_MIN, Clip::SPEED_MAX) } else { 1.0 }
    }
    /// How long the clip lasts in the video.
    pub fn output_duration(&self) -> f64 {
        self.duration() / self.rate()
    }
}

/// A stretch of the first take left out (every pause becomes one).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Cut {
    pub start: f64,
    pub end: f64,
    #[serde(flatten, default, skip_serializing_if = "Map::is_empty")]
    pub extra: Extra,
}

impl Cut {
    pub fn new(start: f64, end: f64) -> Self {
        Cut { start, end, extra: Extra::new() }
    }
}

pub use crate::camera::{CameraClip, CameraCorner, CameraLook, CameraShape};
pub use crate::cursor::{CursorStyle, CursorTint};
pub use crate::music::MusicChoice;
pub use crate::privacy::{BlurRegion, NormRect, TakeCrop};
pub use crate::text::TextOverlay;

macro_rules! edit_defaults {
    ($($f:ident: $t:ty = $v:expr),* $(,)?) => {
        $(pub(super) fn $f() -> $t { $v })*
    };
}
mod d {
    edit_defaults!(
        padding: f64 = 0.07, corner_radius: f64 = 0.018, yes: bool = true, cursor_scale: f64 = 1.5,
        cursor_smoothing: f64 = 0.6, output_width: i64 = 2560, canvas_aspect: f64 = 16.0 / 9.0,
    );
}

/// edit.json: everything chosen in the editor. Every key is optional.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditDoc {
    #[serde(default)]
    pub segments: Vec<ZoomSegment>,
    #[serde(default)]
    pub backdrop: Backdrop,
    /// Space around the recording, as a fraction of the canvas's shorter side.
    #[serde(default = "d::padding")]
    pub padding: f64,
    /// Corner radius, as a fraction of the framed recording's shorter side.
    #[serde(default = "d::corner_radius")]
    pub corner_radius: f64,
    #[serde(default = "d::yes")]
    pub shadow: bool,
    #[serde(default = "d::yes")]
    pub cursor_visible: bool,
    #[serde(default = "d::cursor_scale")]
    pub cursor_scale: f64,
    #[serde(default = "d::cursor_smoothing")]
    pub cursor_smoothing: f64,
    #[serde(default = "d::yes")]
    pub click_ripple: bool,
    #[serde(default)]
    pub cursor_style: CursorStyle,
    #[serde(default)]
    pub cursor_tint: CursorTint,
    #[serde(default)]
    pub cursor_label: String,
    #[serde(default)]
    pub camera_clips: Vec<CameraClip>,
    #[serde(default)]
    pub camera_look: CameraLook,
    #[serde(default = "d::output_width", deserialize_with = "swift_int")]
    pub output_width: i64,
    /// Width / height; 0 means match the recording.
    #[serde(default = "d::canvas_aspect")]
    pub canvas_aspect: f64,
    #[serde(default)]
    pub trim_start: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub trim_end: Option<f64>,
    #[serde(default)]
    pub cuts: Vec<Cut>,
    /// The kept pieces once edited; None = derive from trim and cuts.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub clips: Option<Vec<Clip>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub music: Option<MusicChoice>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub backdrop_image: Option<String>,
    #[serde(default)]
    pub backdrop_blur: f64,
    #[serde(default)]
    pub blurs: Vec<BlurRegion>,
    #[serde(default)]
    pub crops: Vec<TakeCrop>,
    /// Words on the video (None until the first is added, so older edits
    /// stay byte-for-byte as they were).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub texts: Option<Vec<TextOverlay>>,
    /// The format last applied (`formats::Format::id`), for the picker.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub format: Option<String>,
    #[serde(flatten, default, skip_serializing_if = "Map::is_empty")]
    pub extra: Extra,
}

impl Default for EditDoc {
    fn default() -> Self {
        serde_json::from_str("{}").expect("empty edit decodes")
    }
}

impl EditDoc {
    /// The clips that make the video: the explicit list, or the first take's
    /// trim with its pause cuts taken out.
    pub fn kept_clips(&self, duration: f64) -> Vec<Clip> {
        if let Some(c) = &self.clips {
            return c.clone();
        }
        let lo = self.trim_start.max(0.0).min(duration);
        let hi = self.trim_end.unwrap_or(duration).max(lo).min(duration);
        let mut cuts: Vec<&Cut> = self.cuts.iter().collect();
        cuts.sort_by(|a, b| a.start.total_cmp(&b.start));
        let mut out = Vec::new();
        let mut cursor = lo;
        for c in cuts {
            if !(c.end > cursor && c.start < hi) {
                continue;
            }
            if c.start > cursor {
                out.push(Clip::new(cursor, c.start, 0));
            }
            cursor = cursor.max(c.end);
        }
        if hi > cursor {
            out.push(Clip::new(cursor, hi, 0));
        }
        out.retain(|c| c.duration() > 1e-3);
        out
    }

    /// Canvas size in pixels (even height) for a recording of this aspect.
    pub fn canvas_size(&self, recording_aspect: f64) -> (i64, i64) {
        let aspect = if self.canvas_aspect > 0.0 { self.canvas_aspect } else { recording_aspect };
        let w = self.output_width.max(2);
        let h = ((w as f64 / aspect / 2.0).round() as i64) * 2;
        (w, h.max(2))
    }

    /// The texts, in drawing order (later ones on top).
    pub fn overlays(&self) -> &[TextOverlay] {
        self.texts.as_deref().unwrap_or(&[])
    }

    /// Take `take`'s crop (the whole frame when it has none).
    pub fn crop(&self, take: i64) -> NormRect {
        self.crops.iter().find(|c| c.take == take).map(|c| c.rect).unwrap_or(NormRect::FULL)
    }

    /// Sets take `take`'s crop; the whole frame removes it.
    pub fn set_crop(&mut self, rect: NormRect, take: i64) {
        self.crops.retain(|c| c.take != take);
        if !rect.is_full() {
            self.crops.push(TakeCrop::new(take, rect.clamped(0.1)));
        }
        self.crops.sort_by_key(|c| c.take);
    }
}
