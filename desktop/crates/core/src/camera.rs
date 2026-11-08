//! You on camera (clips recorded over the edit, and the bubble's look), and
//! the music's level under your voice.

use crate::model::{new_id, string_enum, upper_id, Extra};
use serde::{Deserialize, Serialize};
use serde_json::Map;

/// You on camera, recorded over the finished video. `at` is output time.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CameraClip {
    #[serde(deserialize_with = "upper_id")]
    pub id: String,
    /// File name inside the .reel folder.
    pub file: String,
    pub at: f64,
    pub duration: f64,
    /// Fill the frame instead of sitting in a bubble.
    pub full: bool,
    #[serde(flatten, default, skip_serializing_if = "Map::is_empty")]
    pub extra: Extra,
}

impl CameraClip {
    pub fn new(file: &str, at: f64, duration: f64, full: bool) -> Self {
        CameraClip { id: new_id(), file: file.into(), at, duration, full, extra: Extra::new() }
    }
    pub fn end(&self) -> f64 {
        self.at + self.duration
    }
    pub fn covers(&self, t: f64) -> bool {
        t >= self.at && t < self.end()
    }
}

string_enum!(CameraShape, default Circle, { Circle = "circle", Rounded = "rounded" });
string_enum!(CameraCorner, default BottomRight, {
    BottomRight = "bottomRight", BottomLeft = "bottomLeft", TopRight = "topRight", TopLeft = "topLeft",
});

impl CameraShape {
    pub fn label(&self) -> &str {
        if self.known() == CameraShape::Circle { "Circle" } else { "Rounded" }
    }
}

fn yes() -> bool {
    true
}
fn size() -> f64 {
    0.27
}

/// How the camera bubble looks: one look for the whole video.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CameraLook {
    #[serde(default = "yes")]
    pub visible: bool,
    #[serde(default)]
    pub shape: CameraShape,
    #[serde(default)]
    pub corner: CameraCorner,
    /// Bubble height as a fraction of the canvas's shorter side.
    #[serde(default = "size")]
    pub size: f64,
    /// Show yourself as in a mirror.
    #[serde(default = "yes")]
    pub mirror: bool,
    /// Lower the music while you talk.
    #[serde(default = "yes")]
    pub duck_music: bool,
    #[serde(flatten, default, skip_serializing_if = "Map::is_empty")]
    pub extra: Extra,
}

impl Default for CameraLook {
    fn default() -> Self {
        serde_json::from_str("{}").expect("empty look decodes")
    }
}

/// The camera fades in and out over this long at a clip's ends.
pub const FADE: f64 = 0.28;

/// Adds `clip`, trimming or removing whatever it records over.
pub fn insert(clip: CameraClip, into: &[CameraClip]) -> Vec<CameraClip> {
    let mut out = Vec::new();
    for c in into {
        if c.end() <= clip.at || c.at >= clip.end() {
            out.push(c.clone());
            continue;
        }
        // The part before survives; the part after is cut off.
        if c.at < clip.at - 0.2 {
            let mut head = c.clone();
            head.duration = clip.at - c.at;
            out.push(head);
        }
    }
    out.push(clip);
    out.sort_by(|a, b| a.at.total_cmp(&b.at));
    out
}

/// 0...1: how present clip `c` is at time `t`.
pub fn presence(c: &CameraClip, t: f64) -> f64 {
    if !c.covers(t) {
        return 0.0;
    }
    let f = FADE.min(c.duration / 3.0);
    if f <= 0.0 {
        return 1.0;
    }
    let x = ((t - c.at).min(c.end() - t) / f).min(1.0);
    x * x * (3.0 - 2.0 * x)
}

/// The music's level over time, ducked under your voice.
pub mod music_envelope {
    pub const DUCK_LEVEL: f64 = 0.3;
    pub const DUCK_RAMP: f64 = 0.45;

    /// Gain at output time `t`, as a fraction of the chosen volume. `voice`
    /// is (start, end) ranges in output time.
    pub fn gain(t: f64, length: f64, fade_in: bool, fade_out: bool, voice: &[(f64, f64)]) -> f64 {
        gain_with(t, length, fade_in, fade_out, None, voice)
    }

    /// As `gain`, with the fade at the end lasting `outro` seconds (None =
    /// 2 s; never over a third of the video), as `MusicEnvelope.gain(outro:)`.
    pub fn gain_with(t: f64, length: f64, fade_in: bool, fade_out: bool, outro: Option<f64>, voice: &[(f64, f64)]) -> f64 {
        let mut g = 1.0;
        let fi = 1.2f64.min(length / 3.0);
        let fo = outro.unwrap_or(2.0).min(length / 3.0);
        if fade_in && fi > 0.0 && t < fi {
            g *= (t / fi).max(0.0);
        }
        if fade_out && fo > 0.0 && t > length - fo {
            g *= ((length - t) / fo).max(0.0);
        }
        let mut duck = 0.0f64;
        for &(lo, hi) in voice {
            let into = (t - (lo - DUCK_RAMP)).min((hi + DUCK_RAMP) - t) / DUCK_RAMP;
            duck = duck.max(into.max(0.0).min(1.0));
        }
        g * (1.0 - duck * (1.0 - DUCK_LEVEL))
    }
}
