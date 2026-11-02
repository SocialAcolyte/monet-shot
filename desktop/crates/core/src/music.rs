//! Music under the video: the library that ships with the app
//! (`Resources/Music/library.json`), a file of your own, and the beat grid
//! the snippet window snaps to. (The Mac's music work is in progress; this
//! follows the working tree as of `shared/LAST_SYNC`.)

use crate::model::Extra;
use serde::{Deserialize, Serialize};
use serde_json::Map;
use std::path::Path;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Song {
    pub id: String,
    pub title: String,
    pub artist: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album: Option<String>,
    /// Seconds.
    pub duration: f64,
    pub genres: Vec<String>,
    /// "cc0", "by", "pdm", "own".
    pub license: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub license_version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "licenseURL")]
    pub license_url: Option<String>,
    #[serde(rename = "audioURL")]
    pub audio_url: String,
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "artworkURL")]
    pub artwork_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "pageURL")]
    pub page_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attribution: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none", deserialize_with = "crate::model::swift_int_opt")]
    pub bpm: Option<i64>,
    /// The composer's own one-line description.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub about: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub instruments: Option<String>,
    #[serde(flatten, default, skip_serializing_if = "Map::is_empty")]
    pub extra: Extra,
}

impl Song {
    pub fn license_label(&self) -> String {
        match self.license.as_str() {
            "cc0" => "CC0".into(),
            "pdm" => "Public domain".into(),
            "own" => "Your file".into(),
            l => format!("CC {}{}", l.to_uppercase(), self.license_version.as_ref().map(|v| format!(" {v}")).unwrap_or_default()),
        }
    }

    /// True when the licence asks for a credit wherever the music is used.
    pub fn needs_credit(&self) -> bool {
        !["cc0", "pdm", "own"].contains(&self.license.as_str())
    }

    /// The line written beside an export that needs a credit.
    pub fn credit_text(&self) -> String {
        let who = self
            .attribution
            .clone()
            .unwrap_or_else(|| format!("\"{}\" by {}, {}", self.title, self.artist, self.license_label()));
        format!("Music: {}\n{}\n", who, self.page_url.clone().unwrap_or_default())
    }

    /// A file of your own, as a song (`duration` from a probe).
    pub fn own_file(path: &Path, duration: f64) -> Song {
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let stem = path.file_stem().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        Song {
            id: format!("own-{name}"),
            title: stem,
            artist: "Your music".into(),
            album: None,
            duration,
            genres: vec![],
            license: "own".into(),
            license_version: None,
            license_url: None,
            audio_url: file_url(path),
            artwork_url: None,
            page_url: None,
            attribution: None,
            bpm: None,
            about: None,
            instruments: None,
            extra: Extra::new(),
        }
    }
}

fn yes() -> bool {
    true
}

/// The music under a recording: the file (inside the .reel folder) and how
/// it sits under the video. Every key is required, as on the Mac.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MusicChoice {
    pub track: Song,
    /// File name inside the .reel folder.
    pub file: String,
    /// Seconds into the song where the video's first frame falls.
    pub offset: f64,
    /// 0...1.
    pub volume: f64,
    #[serde(default = "yes")]
    pub fade_in: bool,
    #[serde(default = "yes")]
    pub fade_out: bool,
    #[serde(flatten, default, skip_serializing_if = "Map::is_empty")]
    pub extra: Extra,
}

impl MusicChoice {
    pub fn new(track: Song, file: &str) -> Self {
        MusicChoice { track, file: file.into(), offset: 0.0, volume: 0.8, fade_in: true, fade_out: true, extra: Extra::new() }
    }
}

/// Moods for browsing: each is one of the composer's own "feel" tags.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct MusicMood {
    pub id: &'static str,
    pub name: &'static str,
    pub feel: &'static str,
    /// Tile colour (sRGB hex).
    pub tint: u32,
}

pub const MOODS: &[MusicMood] = &[
    MusicMood { id: "dreamy", name: "Dreamy", feel: "dreamy", tint: 0x6A5B8A },
    MusicMood { id: "grooving", name: "Grooving", feel: "grooving", tint: 0xC96F4A },
    MusicMood { id: "sunny", name: "Sunny", feel: "sunny", tint: 0xB89B4A },
    MusicMood { id: "mellow", name: "Mellow", feel: "mellow", tint: 0x5F7A73 },
    MusicMood { id: "impressionist", name: "Impressionist", feel: "impressionist", tint: 0x5A6F88 },
];

/// `file://` URL for a path, percent-encoded as Foundation's `absoluteString`.
pub fn file_url(path: &Path) -> String {
    let s = path.to_string_lossy().replace('\\', "/");
    let mut out = String::from(if s.starts_with('/') { "file://" } else { "file:///" });
    for b in s.bytes() {
        let keep = b.is_ascii_alphanumeric() || b"/-._~!$&'()*+,;=:@".contains(&b);
        if keep {
            out.push(b as char)
        } else {
            out.push_str(&format!("%{:02X}", b))
        }
    }
    out
}

/// library.json to songs whose `audio_url` is a file URL in `folder`;
/// anything whose file is missing is skipped.
pub fn parse_library(data: &[u8], folder: &Path) -> serde_json::Result<Vec<Song>> {
    let songs: Vec<Song> = serde_json::from_slice(data)?;
    Ok(songs
        .into_iter()
        .filter_map(|mut s| {
            let file = folder.join(&s.audio_url);
            if !file.exists() {
                return None;
            }
            s.audio_url = file_url(&file);
            Some(s)
        })
        .collect())
}

/// Search words (all must match title, artist, description, mood or
/// instruments) or a mood; nothing = everything.
pub fn search<'a>(songs: &'a [Song], query: &str, mood: Option<&str>) -> Vec<&'a Song> {
    let q = query.to_lowercase();
    let words: Vec<&str> = q.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).collect();
    songs
        .iter()
        .filter(|s| {
            if !words.is_empty() {
                let hay = [
                    s.title.as_str(),
                    s.artist.as_str(),
                    s.about.as_deref().unwrap_or(""),
                    &s.genres.join(" "),
                    s.instruments.as_deref().unwrap_or(""),
                ]
                .join(" ")
                .to_lowercase();
                return words.iter().all(|w| hay.contains(w));
            }
            if let Some(feel) = mood {
                return s.genres.iter().any(|g| g.to_lowercase() == feel);
            }
            true
        })
        .collect()
}

/// A short, stable id for a file name (djb2-xor, base 36), as the Mac's.
pub fn stable_id(s: &str) -> String {
    let mut h: u32 = 5381;
    for b in s.bytes() {
        h = h.wrapping_mul(33) ^ b as u32;
    }
    if h == 0 {
        return "0".into();
    }
    let digits = b"0123456789abcdefghijklmnopqrstuvwxyz";
    let mut out = Vec::new();
    while h > 0 {
        out.push(digits[(h % 36) as usize]);
        h /= 36;
    }
    out.reverse();
    String::from_utf8(out).unwrap()
}

/// The file name a library or own track is copied in as.
pub fn local_file_name(track: &Song, extension: &str) -> String {
    let kind = if track.license == "own" { "music-own" } else { "music" };
    let ext = if extension.is_empty() { "m4a".to_string() } else { extension.to_lowercase() };
    format!("{kind}-{}.{ext}", stable_id(&track.id))
}

/// A song's beat: bar length, first downbeat, and lifts (louder sections
/// coming in on a downbeat).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MusicGrid {
    /// Seconds per bar of four beats.
    pub bar: f64,
    pub first_downbeat: f64,
    pub lifts: Vec<f64>,
}

impl MusicGrid {
    pub fn bpm(&self) -> f64 {
        240.0 / self.bar
    }

    /// The bar line nearest `t` (never before 0).
    pub fn nearest_bar_line(&self, t: f64) -> f64 {
        let k = ((t - self.first_downbeat) / self.bar).round();
        let line = self.first_downbeat + k * self.bar;
        if line < 0.0 { line + self.bar } else { line }
    }

    /// The grid of mono samples at `rate` Hz (the Mac reads at 11025 Hz);
    /// None if there is no steady beat.
    pub fn analyze(samples: &[f32], rate: f64) -> Option<MusicGrid> {
        let hop = 256usize;
        let fps = rate / hop as f64;
        let frames = samples.len() / hop;
        if frames <= (fps * 8.0) as usize {
            return None;
        }
        let mut loud = vec![0.0f64; frames];
        for f in 0..frames {
            let mut e: f32 = 0.0;
            for i in (f * hop)..(f * hop + hop) {
                e += samples[i] * samples[i];
            }
            loud[f] = (e as f64 / hop as f64 + 1e-9).log10();
        }
        let mut onset = vec![0.0f64; frames];
        for f in 1..frames {
            onset[f] = (loud[f] - loud[f - 1]).max(0.0);
        }
        let mean = onset.iter().sum::<f64>() / frames as f64;
        for o in onset.iter_mut() {
            *o = (*o - mean).max(0.0);
        }

        let min_lag = (fps * 60.0 / 180.0) as usize;
        let max_lag = (fps * 60.0 / 70.0) as usize;
        let mut best = (0usize, f64::NEG_INFINITY);
        let mut ac = vec![0.0f64; max_lag + 2];
        for lag in min_lag..=(max_lag + 1) {
            let mut s = 0.0;
            for f in lag..frames {
                s += onset[f] * onset[f - lag];
            }
            ac[lag] = s;
        }
        for lag in min_lag..=max_lag {
            let bpm = 60.0 * fps / lag as f64;
            let w = (-(bpm / 110.0).log2().powi(2) / (2.0 * 0.6 * 0.6)).exp();
            if ac[lag] * w > best.1 {
                best = (lag, ac[lag] * w);
            }
        }
        if !(best.0 > 0 && best.1 > 0.0) {
            return None;
        }
        let l = best.0;
        let (a, b, c) = (ac[l - 1], ac[l], ac[l + 1]);
        let shift = if a - 2.0 * b + c != 0.0 { 0.5 * (a - c) / (a - 2.0 * b + c) } else { 0.0 };
        let coarse = (l as f64 + shift.min(0.5).max(-0.5)) / fps;

        let onset_near = |t: f64| -> f64 {
            let f = (t * fps).round() as i64;
            if f < 1 || f >= frames as i64 {
                return 0.0;
            }
            let f = f as usize;
            onset[f].max(onset[f - 1] * 0.5).max(if f + 1 < frames { onset[f + 1] * 0.5 } else { 0.0 })
        };
        let duration = frames as f64 / fps;
        let mut phase = (0.0f64, -1.0f64);
        let mut period = coarse;
        let mut p = coarse * 0.97;
        while p <= coarse * 1.03 {
            for step in 0..((p * fps) as i64).max(0) {
                let t0 = step as f64 / fps;
                let mut s = 0.0;
                let mut t = t0;
                while t < duration {
                    s += onset_near(t);
                    t += p;
                }
                if s > phase.1 {
                    phase = (t0, s);
                    period = p;
                }
            }
            p += 0.0005;
        }
        let beat = period;
        let bar = beat * 4.0;
        let bar_loud = |start: f64| -> Vec<f64> {
            let mut out = Vec::new();
            let mut t = start;
            while t + bar <= duration {
                let f0 = (t * fps) as usize;
                let f1 = frames.min(((t + bar) * fps) as usize);
                out.push(if f1 > f0 { loud[f0..f1].iter().sum::<f64>() / (f1 - f0) as f64 } else { 0.0 });
                t += bar;
            }
            out
        };
        let mut down = (0usize, f64::NEG_INFINITY);
        for k in 0..4 {
            let start = phase.0 + k as f64 * beat;
            let bars = bar_loud(start);
            if bars.len() <= 2 {
                continue;
            }
            let mut contrast = 0.0;
            for i in 1..bars.len() {
                contrast += (bars[i] - bars[i - 1]).abs();
            }
            let mut hits = 0.0;
            let mut t = start;
            while t < duration {
                hits += onset_near(t);
                t += bar;
            }
            let score = contrast / bars.len() as f64 * 10.0 + hits / phase.1.max(1e-9) * 4.0;
            if score > down.1 {
                down = (k, score);
            }
        }
        // Swift's truncatingRemainder is fmod, as Rust's %.
        let first = (phase.0 + down.0 as f64 * beat) % bar;

        let bars = bar_loud(first);
        if bars.is_empty() {
            return Some(MusicGrid { bar, first_downbeat: first, lifts: vec![] });
        }
        let mut sorted = bars.clone();
        sorted.sort_by(|a, b| a.total_cmp(b));
        let typical = sorted[sorted.len() / 2];
        let mut lifts: Vec<(f64, f64)> = Vec::new();
        for i in 1..bars.len() {
            let rise = (bars[i] - bars[i - 1]) * 10.0;
            if rise >= 2.0 && bars[i] >= typical - 0.15 {
                lifts.push((first + i as f64 * bar, rise));
            }
        }
        lifts.sort_by(|a, b| b.1.total_cmp(&a.1));
        let mut kept: Vec<(f64, f64)> = Vec::new();
        for l in lifts {
            if kept.iter().all(|k| (k.0 - l.0).abs() >= bar * 4.0 - 0.01) {
                kept.push(l);
                if kept.len() == 6 {
                    break;
                }
            }
        }
        let mut out: Vec<f64> = kept.iter().map(|k| k.0).collect();
        out.sort_by(|a, b| a.total_cmp(b));
        Some(MusicGrid { bar, first_downbeat: first, lifts: out })
    }
}
