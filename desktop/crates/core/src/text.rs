//! Words on the video (`Sources/MonetShotKit/Model/Text.swift`): titles,
//! captions and labels in output time, how each one moves in, and pure
//! edits. The picture of the words is drawn by the export crate's
//! `text_art`, which the preview uses too.

use crate::model::{new_id, string_enum, upper_id, Extra};
use serde::{Deserialize, Serialize};
use serde_json::Map;

string_enum!(
    /// Title (big), caption (a line on a dark box) or label (a small pill).
    TextStyle, default Title, { Title = "title", Caption = "caption", Label = "label" }
);
string_enum!(
    /// How a text comes in.
    TextAnimation, default Rise, { Fade = "fade", Rise = "rise", Pop = "pop", Words = "words" }
);
string_enum!(TextTone, default Light, { Light = "light", Dark = "dark", Clay = "clay" });

impl TextStyle {
    pub fn label(&self) -> &str {
        match self.known() {
            TextStyle::Caption => "Caption",
            TextStyle::Label => "Label",
            _ => "Title",
        }
    }
    /// Font size as a fraction of the canvas's shorter side.
    pub fn em(&self) -> f64 {
        match self.known() {
            TextStyle::Caption => 0.042,
            TextStyle::Label => 0.036,
            _ => 0.085,
        }
    }
    /// Extra space between letters, in ems.
    pub fn tracking(&self) -> f64 {
        match self.known() {
            TextStyle::Caption => 0.0,
            TextStyle::Label => 0.02,
            _ => -0.01,
        }
    }
    pub fn backed(&self) -> bool {
        self.known() != TextStyle::Title
    }
    /// Where a new one goes.
    pub fn place(&self) -> (f64, f64) {
        match self.known() {
            TextStyle::Caption => (0.5, 0.86),
            TextStyle::Label => (0.5, 0.2),
            _ => (0.5, 0.45),
        }
    }
}

impl TextAnimation {
    pub fn label(&self) -> &str {
        match self.known() {
            TextAnimation::Fade => "Fade",
            TextAnimation::Pop => "Pop",
            TextAnimation::Words => "Word by word",
            _ => "Rise",
        }
    }
}

impl TextTone {
    pub fn label(&self) -> &str {
        match self.known() {
            TextTone::Dark => "Dark",
            TextTone::Clay => "Clay",
            _ => "Light",
        }
    }
    /// The words' colour (sRGB).
    pub fn hex(&self) -> u32 {
        match self.known() {
            TextTone::Dark => 0x17191B,
            TextTone::Clay => 0xE07A55,
            _ => 0xF7F4EE,
        }
    }
    /// The box behind them, and its opacity.
    pub fn backing_hex(&self) -> u32 {
        if self.known() == TextTone::Dark { 0xF3F0E8 } else { 0x17191B }
    }
    pub fn backing_alpha(&self) -> f64 {
        if self.known() == TextTone::Dark { 0.92 } else { 0.72 }
    }
    /// The word being said, in a caption.
    pub fn highlight_hex(&self) -> u32 {
        if self.known() == TextTone::Clay { 0xF7F4EE } else { 0xE07A55 }
    }
}

fn one() -> f64 {
    1.0
}
fn half() -> f64 {
    0.5
}

/// One text on the video. `at` and `duration` are output time; `x`/`y` the
/// block's centre on the canvas, 0...1.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TextOverlay {
    #[serde(deserialize_with = "upper_id")]
    pub id: String,
    #[serde(default)]
    pub text: String,
    pub at: f64,
    pub duration: f64,
    #[serde(default)]
    pub style: TextStyle,
    #[serde(default)]
    pub animation: TextAnimation,
    #[serde(default = "half")]
    pub x: f64,
    #[serde(default = "half")]
    pub y: f64,
    /// Size relative to the style's own.
    #[serde(default = "one")]
    pub size: f64,
    #[serde(default)]
    pub tone: TextTone,
    /// A soft box behind the words (None = the style's choice).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub backing: Option<bool>,
    #[serde(default)]
    pub uppercase: bool,
    /// When each word is spoken, seconds after `at` (captions from a
    /// transcript); None for a text typed in.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub beats: Option<Vec<f64>>,
    #[serde(flatten, default, skip_serializing_if = "Map::is_empty")]
    pub extra: Extra,
}

impl TextOverlay {
    pub fn new(text: &str, at: f64, duration: f64, style: TextStyle, animation: TextAnimation) -> Self {
        let (x, y) = style.place();
        TextOverlay {
            id: new_id(),
            text: text.into(),
            at,
            duration,
            style,
            animation,
            x,
            y,
            size: 1.0,
            tone: TextTone::Light,
            backing: None,
            uppercase: false,
            beats: None,
            extra: Extra::new(),
        }
    }
    pub fn end(&self) -> f64 {
        self.at + self.duration
    }
    pub fn covers(&self, t: f64) -> bool {
        t >= self.at && t < self.end()
    }
    pub fn has_backing(&self) -> bool {
        self.backing.unwrap_or_else(|| self.style.backed())
    }
}

/// How a text looks at one moment.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TextState {
    /// The lines as drawn (upper-cased if asked).
    pub lines: Vec<String>,
    /// Font size in canvas pixels.
    pub px: f64,
    pub tracking: f64,
    /// Centre of the block (canvas pixels, top-left origin), rise applied.
    pub center_x: f64,
    pub center_y: f64,
    pub opacity: f64,
    pub scale: f64,
    /// One per word in reading order; empty unless the words come one by one.
    pub words: Vec<f64>,
    /// The word being said (reading order), lit in the tone's highlight.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub highlight: Option<usize>,
}

/// The layout constants and the animation, as `TextMotion` on the Mac.
pub mod text_motion {
    use super::*;

    /// Line box height and where the baseline sits in it, in ems.
    pub const LINE_HEIGHT: f64 = 1.22;
    pub const BASELINE: f64 = 0.94;
    /// Padding of the picture (and its backing box) in ems, and the box's corner radius.
    pub const PAD_X: f64 = 0.55;
    pub const PAD_Y: f64 = 0.32;
    pub const RADIUS: f64 = 0.38;
    /// Unboxed light words carry a soft shadow in the picture itself.
    pub const SHADOW_OFFSET: f64 = 0.035;
    pub const SHADOW_SIGMA: f64 = 0.07;
    pub const SHADOW_ALPHA: f64 = 0.5;

    pub fn has_shadow(tone: &TextTone, backing: bool) -> bool {
        !backing && tone.known() != TextTone::Dark
    }

    fn smooth(x: f64) -> f64 {
        let u = x.clamp(0.0, 1.0);
        u * u * (3.0 - 2.0 * u)
    }
    fn ease_out(x: f64) -> f64 {
        let u = x.clamp(0.0, 1.0);
        1.0 - (1.0 - u).powf(3.0)
    }
    fn ease_out_back(x: f64) -> f64 {
        let u = x.clamp(0.0, 1.0);
        let (c1, c3) = (1.70158, 1.70158 + 1.0);
        1.0 + c3 * (u - 1.0).powf(3.0) + c1 * (u - 1.0).powf(2.0)
    }

    /// The words of a line, split as every app splits them.
    pub fn words(line: &str) -> Vec<&str> {
        line.split([' ', '\t']).filter(|w| !w.is_empty()).collect()
    }

    /// The text at output time `t` on a `width` x `height` canvas; None when it isn't showing.
    pub fn state(o: &TextOverlay, t: f64, width: f64, height: f64) -> Option<TextState> {
        if !(o.duration > 0.01 && o.covers(t)) {
            return None;
        }
        let shown = if o.uppercase { o.text.to_uppercase() } else { o.text.clone() };
        let lines: Vec<String> = shown.split('\n').map(String::from).collect();
        if !lines.iter().any(|l| !l.trim().is_empty()) {
            return None;
        }
        let short = width.min(height);
        let px = (o.style.em() * o.size.clamp(0.25, 4.0) * short).round();
        let (into, left) = (t - o.at, o.end() - t);
        let anim = o.animation.known();
        // Spoken captions come and go quickly: a phrase follows the voice.
        let beats = o.beats.as_deref().filter(|b| !b.is_empty());
        let spoken = beats.is_some();
        let in_dur = (if spoken { 0.18 } else if anim == TextAnimation::Pop { 0.32f64 } else { 0.45 }).min(o.duration / 4.0);
        let out_dur = (if spoken { 0.12f64 } else { 0.35 }).min(o.duration / 4.0);
        let u = into / in_dur;
        let mut opacity = smooth(left / out_dur);
        let mut scale = 1.0;
        let mut rise = 0.0;
        let mut arrive = vec![];
        match anim {
            TextAnimation::Fade => opacity = opacity.min(smooth(u)),
            TextAnimation::Pop => {
                opacity = opacity.min(smooth(u * 1.6));
                scale = 0.82 + 0.18 * ease_out_back(u);
            }
            TextAnimation::Words => {
                let n: usize = lines.iter().map(|l| words(l).len()).sum();
                if let Some(b) = beats {
                    // Each word arrives as it is said.
                    arrive = (0..n).map(|k| smooth((into - b[k.min(b.len() - 1)]) / 0.12)).collect();
                } else {
                    // The words arrive over the first ~60% of the text's time, at most 0.32 s apart.
                    let step = 0.32f64.min(o.duration * 0.6 / n.max(1) as f64);
                    arrive = (0..n).map(|k| smooth((into - k as f64 * step) / 0.22)).collect();
                }
            }
            _ => {
                opacity = opacity.min(smooth(u));
                rise = (1.0 - ease_out(u)) * 0.035 * short;
            }
        }
        let highlight = beats.and_then(|b| b.iter().rposition(|&x| x <= into));
        Some(TextState {
            lines,
            px,
            tracking: o.style.tracking(),
            center_x: (o.x * width).round(),
            center_y: (o.y * height).round() + rise,
            opacity,
            scale,
            words: arrive,
            highlight,
        })
    }
}

/// Pure edits to the texts, as `TextEdits` on the Mac.
pub mod text_edits {
    use super::*;

    pub const MIN_LENGTH: f64 = 0.4;

    /// A new text at output time `t`, lasting `duration` but never past the end of the video.
    pub fn insert(text: &str, style: TextStyle, animation: TextAnimation, t: f64, video_length: f64, duration: f64) -> TextOverlay {
        let length = MIN_LENGTH.max(duration.min(video_length));
        let start = 0f64.max(t.min(video_length - length));
        TextOverlay::new(text, start, MIN_LENGTH.max(length.min(video_length - start)), style, animation)
    }

    /// Moves a text to start at `at`, kept inside the video.
    pub fn move_to(o: &TextOverlay, at: f64, video_length: f64) -> TextOverlay {
        let mut o = o.clone();
        o.at = 0f64.max(at.min(video_length - o.duration));
        o
    }

    /// Moves one end of a text to `t`, at least MIN_LENGTH long and inside the video.
    pub fn resize(o: &TextOverlay, leading: bool, t: f64, video_length: f64) -> TextOverlay {
        let mut o = o.clone();
        if leading {
            let a = 0f64.max(t.min(o.end() - MIN_LENGTH));
            o.duration = o.end() - a;
            o.at = a;
        } else {
            o.duration = MIN_LENGTH.max(t.min(video_length) - o.at);
        }
        o
    }
}
