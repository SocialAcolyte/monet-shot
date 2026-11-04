//! Formats (`Sources/MonetShotKit/Model/Format.swift`): a pace and a look in
//! one go. Applying one writes speeds, fades, zoom depth, backdrop, framing,
//! cursor glide and how texts come in into the edit; everything stays
//! adjustable afterwards, and the edit remembers the format's id.

use crate::model::{Backdrop, EditDoc};
use crate::text::{TextAnimation, TextOverlay, TextStyle};
use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Format {
    pub id: &'static str,
    pub name: &'static str,
    pub blurb: &'static str,
    /// Every clip's speed.
    pub speed: f64,
    /// Fades on every clip (output seconds), and longer ones at the very start and end.
    pub clip_fade: f64,
    pub open_fade: f64,
    pub close_fade: f64,
    /// Depth of the auto zooms (hand-made ones keep theirs).
    pub zoom_scale: f64,
    #[serde(skip)]
    pub backdrop: Backdrop,
    pub padding: f64,
    pub corner_radius: f64,
    pub cursor_smoothing: f64,
    #[serde(skip)]
    pub title_animation: TextAnimation,
    #[serde(skip)]
    pub caption_animation: TextAnimation,
    #[serde(skip)]
    pub label_animation: TextAnimation,
    pub uppercase_titles: bool,
    /// The music browser's mood to suggest.
    pub music_mood: &'static str,
}

impl Format {
    /// `doc` in this format. `duration` is the first take's.
    pub fn apply(&self, doc: &EditDoc, duration: f64) -> EditDoc {
        let mut d = doc.clone();
        let mut clips = doc.kept_clips(duration);
        let last = clips.len().saturating_sub(1);
        for (i, c) in clips.iter_mut().enumerate() {
            c.speed = self.speed;
            c.fade_in = if i == 0 { self.open_fade } else { self.clip_fade };
            c.fade_out = if i == last { self.close_fade } else { self.clip_fade };
        }
        d.clips = Some(clips);
        d.cuts = vec![];
        d.trim_start = 0.0;
        d.trim_end = None;
        for s in d.segments.iter_mut().filter(|s| s.auto) {
            s.scale = self.zoom_scale;
        }
        // A picture of your own stays; the colours follow the format.
        if d.backdrop.known() != Backdrop::Image {
            d.backdrop = self.backdrop.clone();
        }
        d.padding = self.padding;
        d.corner_radius = self.corner_radius;
        d.cursor_smoothing = self.cursor_smoothing;
        if let Some(texts) = &d.texts {
            d.texts = Some(texts.iter().map(|o| self.styled(o)).collect());
        }
        d.format = Some(self.id.to_string());
        d
    }

    /// A text as this format brings it in.
    pub fn styled(&self, o: &TextOverlay) -> TextOverlay {
        let mut o = o.clone();
        match o.style.known() {
            TextStyle::Caption => o.animation = self.caption_animation.clone(),
            TextStyle::Label => o.animation = self.label_animation.clone(),
            _ => {
                o.animation = self.title_animation.clone();
                o.uppercase = self.uppercase_titles;
            }
        }
        o
    }
}

pub fn all() -> Vec<Format> {
    use TextAnimation::*;
    vec![
        Format {
            id: "clean",
            name: "Clean",
            blurb: "The everyday look: real time, straight cuts, gentle zooms.",
            speed: 1.0,
            clip_fade: 0.0,
            open_fade: 0.0,
            close_fade: 0.0,
            zoom_scale: 2.0,
            backdrop: Backdrop::Paper,
            padding: 0.07,
            corner_radius: 0.018,
            cursor_smoothing: 0.6,
            title_animation: Rise,
            caption_animation: Words,
            label_animation: Pop,
            uppercase_titles: false,
            music_mood: "sunny",
        },
        Format {
            id: "fast",
            name: "Fast pace",
            blurb: "Half as fast again, hard cuts, deep zooms and words that pop.",
            speed: 1.5,
            clip_fade: 0.0,
            open_fade: 0.0,
            close_fade: 0.3,
            zoom_scale: 2.4,
            backdrop: Backdrop::Slate,
            padding: 0.05,
            corner_radius: 0.024,
            cursor_smoothing: 0.35,
            title_animation: Pop,
            caption_animation: Words,
            label_animation: Pop,
            uppercase_titles: true,
            music_mood: "grooving",
        },
        Format {
            id: "melancholic",
            name: "Melancholic",
            blurb: "Slower, every clip fading through dusk, soft zooms, quiet words.",
            speed: 0.85,
            clip_fade: 0.8,
            open_fade: 1.6,
            close_fade: 2.0,
            zoom_scale: 1.6,
            backdrop: Backdrop::Dusk,
            padding: 0.1,
            corner_radius: 0.03,
            cursor_smoothing: 0.85,
            title_animation: Fade,
            caption_animation: Fade,
            label_animation: Fade,
            uppercase_titles: false,
            music_mood: "mellow",
        },
        Format {
            id: "cinematic",
            name: "Cinematic",
            blurb: "Opens and closes on long fades, brief dips between clips, titles in capitals.",
            speed: 1.0,
            clip_fade: 0.35,
            open_fade: 1.4,
            close_fade: 1.4,
            zoom_scale: 1.8,
            backdrop: Backdrop::Charcoal,
            padding: 0.06,
            corner_radius: 0.012,
            cursor_smoothing: 0.75,
            title_animation: Rise,
            caption_animation: Fade,
            label_animation: Fade,
            uppercase_titles: true,
            music_mood: "dreamy",
        },
    ]
}

pub fn named(id: &str) -> Option<Format> {
    all().into_iter().find(|f| f.id == id)
}
