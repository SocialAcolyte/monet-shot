//! How music fits the edit, as the Mac's `MusicFit.swift`: where a voice is
//! talking (by level alone), where a song starts and how long its end fade
//! lasts, how fast a song feels, and which songs suit a video.
//! `shared/fixtures/music_fit.json` keeps the two in step.

use crate::music::{MusicGrid, Song};
use std::collections::HashSet;

/// Where someone is talking in a take's sound (`VoiceActivity`).
pub mod voice {
    /// Seconds per level frame.
    pub const HOP: f64 = 0.05;
    /// A pause shorter than this is still talking.
    pub const BRIDGE: f64 = 0.5;
    /// A burst shorter than this is a click, a breath or a bump.
    pub const SHORTEST: f64 = 0.2;

    /// Level (dBFS, RMS) of each `HOP`-long frame of mono `samples` at `rate` Hz.
    pub fn levels(samples: &[f32], rate: f64) -> Vec<f64> {
        let n = ((rate * HOP).round() as usize).max(1);
        let frames = samples.len() / n;
        let mut out = vec![-120.0f64; frames];
        for (f, o) in out.iter_mut().enumerate() {
            let mut e = 0.0f64;
            for &x in &samples[f * n..f * n + n] {
                e += x as f64 * x as f64;
            }
            *o = (10.0 * (e / n as f64 + 1e-12).log10()).max(-120.0);
        }
        out
    }

    /// The level above which a frame is voice.
    pub fn threshold(levels: &[f64]) -> f64 {
        if levels.is_empty() {
            return 0.0;
        }
        let mut sorted = levels.to_vec();
        sorted.sort_by(|a, b| a.total_cmp(b));
        let floor = sorted[(sorted.len() / 10).min(sorted.len() - 1)];
        (floor + 12.0).max(-48.0).min(-26.0)
    }

    /// Talking ranges (start, end) in seconds from frame levels.
    pub fn ranges(levels: &[f64]) -> Vec<(f64, f64)> {
        let thr = threshold(levels);
        let mut runs: Vec<(usize, usize)> = Vec::new();
        let mut start: Option<usize> = None;
        for (i, &l) in levels.iter().enumerate() {
            if l >= thr {
                if start.is_none() {
                    start = Some(i);
                }
            } else if let Some(s) = start.take() {
                runs.push((s, i));
            }
        }
        if let Some(s) = start {
            runs.push((s, levels.len()));
        }
        let gap = (BRIDGE / HOP).round() as usize;
        let mut merged: Vec<(usize, usize)> = Vec::new();
        for r in runs {
            if merged.last().is_some_and(|last| r.0 - last.1 <= gap) {
                merged.last_mut().unwrap().1 = r.1;
            } else {
                merged.push(r);
            }
        }
        let least = (SHORTEST / HOP).round() as usize;
        merged.into_iter().filter(|r| r.1 - r.0 >= least).map(|r| (r.0 as f64 * HOP, r.1 as f64 * HOP)).collect()
    }

    /// Talking ranges of mono `samples` at `rate` Hz.
    pub fn ranges_of(samples: &[f32], rate: f64) -> Vec<(f64, f64)> {
        ranges(&levels(samples, rate))
    }
}

/// The plain fade at the end when the song has no beat to go by.
pub const PLAIN_OUTRO: f64 = 2.0;

/// The last line of every `bars` bars at or before `t` (song time).
fn line_before(t: f64, g: &MusicGrid, bars: u32) -> f64 {
    let step = g.bar * bars as f64;
    g.first_downbeat + ((t - g.first_downbeat) / step).floor() * step
}

/// The shortest fade the end may have: a bar, never under 1.5 s.
fn shortest_outro(g: &MusicGrid) -> f64 {
    g.bar.max(1.5)
}

/// From the last phrase line that leaves at least the shortest fade, to `end`.
fn phrase_fade(g: &MusicGrid, end: f64) -> f64 {
    end - line_before(end - shortest_outro(g), g, 4)
}

/// Seconds the fade at the end lasts (`MusicFit.outro`).
pub fn outro(grid: Option<&MusicGrid>, offset: f64, length: f64) -> f64 {
    let cap = length / 3.0;
    let g = match grid {
        Some(g) if g.bar > 0.0 && length > 0.0 => g,
        _ => return PLAIN_OUTRO.min(cap),
    };
    let end = offset + length;
    let phrase = phrase_fade(g, end);
    let fade = if phrase <= (2.0 * g.bar).max(4.0) { phrase } else { end - line_before(end - shortest_outro(g), g, 1) };
    fade.min(cap).max(0.0)
}

/// Where in the song a video `length` long starts, and its outro (`MusicFit.place`).
pub fn place(grid: Option<&MusicGrid>, song_duration: f64, length: f64, from: Option<f64>, punchy: bool) -> (f64, f64) {
    let g = match grid {
        Some(g) if g.bar > 0.0 && length > 0.0 => g,
        _ => {
            let o = from.unwrap_or(0.0).max(0.0).min((song_duration - length).max(0.0));
            return (o, PLAIN_OUTRO.min((length / 3.0).max(0.0)));
        }
    };
    let mut start = from.unwrap_or(g.first_downbeat).max(0.0);
    if punchy {
        if let Some(&lift) = g.lifts.iter().find(|&&l| l >= start - 0.01 && l + length <= song_duration) {
            start = lift;
        }
    }
    let choices = |t: f64| -> Vec<f64> {
        let at = line_before(t + 0.001, g, 1);
        let down = if at < t - 0.001 { at + g.bar } else { at };
        (0..4).map(|k| down + k as f64 * g.bar).filter(|s| s + length <= song_duration + 0.01).collect()
    };
    let mut options = choices(start);
    if options.is_empty() {
        options = choices(g.first_downbeat.max(0.0));
    }
    if options.is_empty() {
        let down = g.first_downbeat.max(0.0);
        return (down, outro(Some(g), down, length));
    }
    let mut best = options[0];
    for &s in &options[1..] {
        if phrase_fade(g, s + length) < phrase_fade(g, best + length) - 1e-9 {
            best = s;
        }
    }
    (best, outro(Some(g), best, length))
}

/// Calm, steady or upbeat (`MusicTempo.of`): the library says; otherwise its bpm.
pub fn tempo(s: &Song) -> Option<&'static str> {
    if let Some(t) = s.tempo.as_deref() {
        match t {
            "calm" => return Some("calm"),
            "steady" => return Some("steady"),
            "upbeat" => return Some("upbeat"),
            _ => {}
        }
    }
    let bpm = s.bpm.or_else(|| s.grid.as_ref().map(|g| g.bpm().round() as i64))?;
    Some(if bpm < 90 {
        "calm"
    } else if bpm <= 115 {
        "steady"
    } else {
        "upbeat"
    })
}

/// How well a song suits a video (`MusicSuggest.score`).
pub fn suggest_score(s: &Song, length: f64, mood: Option<&str>, vertical: bool, favourite: bool) -> f64 {
    let mut x = 0.0;
    if let Some(m) = mood {
        if s.genres.iter().any(|g| g == m) {
            x += 3.0;
        }
    }
    let energy = s.energy.unwrap_or(0.5);
    let t = tempo(s);
    if vertical {
        x += 2.5 * energy
            + match t {
                Some("upbeat") => 1.0,
                Some("calm") => -1.0,
                _ => 0.0,
            };
    } else {
        x += 1.0 - (energy - 0.5).abs();
    }
    let playable = s.duration - s.start.unwrap_or(0.0);
    if length > 0.0 {
        x += if playable >= length { 1.0 } else { -4.0 * (1.0 - playable.max(0.0) / length) };
    }
    if favourite {
        x += 0.75;
    }
    x
}

/// The best `count` songs for a video, ties in library order (`MusicSuggest.rank`).
pub fn suggest<'a>(songs: &'a [Song], length: f64, mood: Option<&str>, vertical: bool, favourites: &HashSet<String>, count: usize) -> Vec<&'a Song> {
    let mut scored: Vec<(usize, &Song, f64)> =
        songs.iter().enumerate().map(|(i, s)| (i, s, suggest_score(s, length, mood, vertical, favourites.contains(&s.id)))).collect();
    scored.sort_by(|a, b| if (a.2 - b.2).abs() > 1e-9 { b.2.total_cmp(&a.2) } else { a.0.cmp(&b.0) });
    scored.into_iter().take(count).map(|x| x.1).collect()
}
