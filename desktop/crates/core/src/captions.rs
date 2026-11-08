//! What was said in a take (`transcript.json`) and the captions made from
//! it: a port of `Sources/MonetShotKit/Model/Captions.swift`, checked by
//! `shared/fixtures/captions.json`.

use crate::model::Extra;
use crate::plan::Rect;
use crate::vertical::{safe_area, safe_area_is_inset};
use crate::text::{text_motion, TextAnimation, TextOverlay, TextStyle};
use crate::timemap::TimeMap;
use serde::{Deserialize, Serialize};
use serde_json::Map;

/// `transcript.json` in a take's folder. Times are the take's own.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct Transcript {
    /// The words in the order said (sorted by `start`).
    #[serde(default)]
    pub words: Vec<TranscriptWord>,
    /// The language heard or chosen ("en", "fr", …), if known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    /// What heard it: "apple" or "whisper".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub engine: Option<String>,
    #[serde(flatten, default, skip_serializing_if = "Map::is_empty")]
    pub extra: Extra,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TranscriptWord {
    pub text: String,
    /// Take seconds.
    pub start: f64,
    pub end: f64,
}

pub const FILE_NAME: &str = "transcript.json";

impl Transcript {
    /// The take's transcript, if it has one.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn load(take_folder: &std::path::Path) -> Option<Transcript> {
        let b = std::fs::read(take_folder.join(FILE_NAME)).ok()?;
        crate::json::from_json(&b).ok()
    }

    #[cfg(not(target_arch = "wasm32"))]
    pub fn save(&self, take_folder: &std::path::Path) -> std::io::Result<()> {
        crate::project::write_json(self, &take_folder.join(FILE_NAME))
    }

    /// Word `i` spelled `text` instead; an empty text removes it.
    pub fn editing(&self, i: usize, text: &str) -> Transcript {
        let mut t = self.clone();
        if i >= t.words.len() {
            return t;
        }
        let clean = pieces(text).join(" ");
        if clean.is_empty() {
            t.words.remove(i);
        } else {
            t.words[i].text = clean;
        }
        t
    }
}

/// A transcript word placed in the video (output time), and which clip shows it.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CaptionWord {
    pub text: String,
    pub start: f64,
    pub end: f64,
    pub span: usize,
    /// Its take and index in that take's transcript, for editing it.
    pub take: i64,
    pub index: usize,
}

pub const MAX_WORDS: usize = 6;
pub const MAX_CHARS: usize = 38;
pub const LINE_CHARS: usize = 20;
pub const PAUSE: f64 = 0.6;
pub const TAIL: f64 = 0.35;
pub const MIN_LENGTH: f64 = 0.6;

/// A word split where every app splits (spaces, tabs, line breaks).
pub fn pieces(s: &str) -> Vec<&str> {
    s.split([' ', '\t', '\n', '\r']).filter(|w| !w.is_empty()).collect()
}

fn length(s: &str) -> usize {
    s.chars().count()
}

/// Every transcribed word the edit shows, in output time and play order.
/// A word belongs to the clip that shows its middle; `transcripts[k]` is take k's.
pub fn words(transcripts: &[Option<Transcript>], map: &TimeMap) -> Vec<CaptionWord> {
    let mut out = vec![];
    for (i, s) in map.spans.iter().enumerate() {
        let Some(Some(tr)) = usize::try_from(s.take).ok().and_then(|k| transcripts.get(k)) else { continue };
        for (k, w) in tr.words.iter().enumerate() {
            let mid = (w.start + w.end) / 2.0;
            if !(mid >= s.start && mid < s.end) {
                continue;
            }
            let (a, b) = (w.start.max(s.start), w.end.min(s.end));
            for p in pieces(&w.text) {
                out.push(CaptionWord {
                    text: p.to_string(),
                    start: s.at + (a - s.start) / s.speed,
                    end: s.at + (b - s.start) / s.speed,
                    span: i,
                    take: s.take,
                    index: k,
                });
            }
        }
    }
    out
}

fn ends_sentence(s: &str) -> bool {
    s.chars().last().is_some_and(|c| ".!?…".contains(c))
}

/// The words grouped into phrases (see the Swift for the rules).
pub fn phrases(words: &[CaptionWord]) -> Vec<Vec<CaptionWord>> {
    let mut out = vec![];
    let mut cur: Vec<CaptionWord> = vec![];
    let mut chars = 0;
    for w in words {
        if let Some(last) = cur.last() {
            if cur.len() >= MAX_WORDS
                || w.span != last.span
                || w.start - last.end > PAUSE
                || ends_sentence(&last.text)
                || chars + 1 + length(&w.text) > MAX_CHARS
            {
                out.push(std::mem::take(&mut cur));
            }
        }
        chars = if cur.is_empty() { length(&w.text) } else { chars + 1 + length(&w.text) };
        cur.push(w.clone());
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

/// A phrase's words as drawn: one line, or two balanced ones.
pub fn lines<S: AsRef<str>>(words: &[S]) -> String {
    let words: Vec<&str> = words.iter().map(|w| w.as_ref()).collect();
    let total = words.iter().map(|w| length(w)).sum::<usize>() + words.len().saturating_sub(1);
    if total <= LINE_CHARS || words.len() < 2 {
        return words.join(" ");
    }
    let (mut best, mut best_diff) = (1, usize::MAX);
    for j in 1..words.len() {
        let a = words[..j].iter().map(|w| length(w)).sum::<usize>() + (j - 1);
        let b = total - a - 1;
        if a.abs_diff(b) < best_diff {
            best_diff = a.abs_diff(b);
            best = j;
        }
    }
    format!("{}\n{}", words[..best].join(" "), words[best..].join(" "))
}

/// Caption size relative to the caption style's own: bigger on a tall canvas.
pub fn size(width: f64, height: f64) -> f64 {
    if height > width { 1.25 } else { 1.0 }
}

/// The captions as texts over a `width` x `height` canvas, coming in as
/// `animation` (the format's caption animation), in output time.
pub fn overlays(transcripts: &[Option<Transcript>], map: &TimeMap, width: f64, height: f64, animation: TextAnimation) -> Vec<TextOverlay> {
    let groups = phrases(&words(transcripts, map));
    // A tall canvas: what phones leave clear. Any other: 6% in from the edges.
    let safe = if safe_area_is_inset(width, height) {
        safe_area(width, height)
    } else {
        Rect::new(width * 0.06, height * 0.06, width * 0.88, height * 0.88)
    };
    let short = width.min(height);
    let size = size(width, height);
    let px = (TextStyle::Caption.em() * size * short).round();
    let mut out = vec![];
    for (k, p) in groups.iter().enumerate() {
        let (Some(first), Some(last)) = (p.first(), p.last()) else { continue };
        let next = groups.get(k + 1).map_or(map.duration(), |g| g[0].start);
        let end = (last.end + TAIL).max(first.start + MIN_LENGTH).min(next).min(map.duration());
        if end - first.start <= 0.05 {
            continue;
        }
        let text = lines(&p.iter().map(|w| w.text.as_str()).collect::<Vec<_>>());
        let count = if text.contains('\n') { 2.0 } else { 1.0 };
        let block = count * text_motion::LINE_HEIGHT * px + 2.0 * text_motion::PAD_Y * px;
        let y = (safe.max_y() - 0.03 * short - block / 2.0) / height;
        let mut o = TextOverlay::new(&text, first.start, end - first.start, TextStyle::Caption, animation.clone());
        o.id = format!("C0000000-0000-4000-8000-{k:012X}");
        o.x = (safe.x + safe.w / 2.0) / width;
        o.y = y;
        o.size = size;
        o.beats = Some(p.iter().map(|w| w.start - first.start).collect());
        out.push(o);
    }
    out
}

/// The captions as SubRip subtitles.
pub fn srt(overlays: &[TextOverlay]) -> String {
    fn stamp(t: f64) -> String {
        let ms = (t.max(0.0) * 1000.0).round() as i64;
        format!("{:02}:{:02}:{:02},{:03}", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
    overlays
        .iter()
        .enumerate()
        .map(|(k, o)| format!("{}\n{} --> {}\n{}\n", k + 1, stamp(o.at), stamp(o.end()), o.text))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Plain text of everything said, in play order: a new paragraph after a long pause.
pub fn text(words: &[CaptionWord]) -> String {
    let mut out = String::new();
    let mut prev: Option<&CaptionWord> = None;
    for w in words {
        if let Some(p) = prev {
            out.push_str(if w.start - p.end > 1.5 { "\n\n" } else { " " });
        }
        out.push_str(&w.text);
        prev = Some(w);
    }
    out
}
