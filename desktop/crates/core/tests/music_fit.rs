//! `shared/fixtures/music_fit.json` (from the Swift MonetShotKit): voice
//! ranges by level, where a song starts and how its end fades, tempo, and
//! the suggestions for a video.

use monetshot_core::music::{self, MusicGrid, Song};
use monetshot_core::music_fit::{self, voice};
use serde_json::Value;
use std::collections::HashSet;
use std::path::PathBuf;

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn fixture(name: &str) -> Value {
    let p = repo().join("shared/fixtures").join(name);
    let bytes = std::fs::read(&p).unwrap_or_else(|e| panic!("{}: {e} (run shared/tools/fixtures.sh)", p.display()));
    serde_json::from_slice(&bytes).unwrap()
}

fn f(v: &Value) -> f64 {
    v.as_f64().unwrap_or_else(|| panic!("not a number: {v}"))
}

fn arr(v: &Value) -> &Vec<Value> {
    v.as_array().unwrap_or_else(|| panic!("not an array: {v}"))
}

#[track_caller]
fn near(a: f64, b: f64, tol: f64, what: &str) {
    assert!((a - b).abs() <= tol * (1.0 + a.abs().max(b.abs())), "{what}: rust {a} vs mac {b}");
}

fn ranges(v: &Value) -> Vec<(f64, f64)> {
    arr(v).iter().map(|p| (f(&p[0]), f(&p[1]))).collect()
}

#[track_caller]
fn same_ranges(a: &[(f64, f64)], b: &[(f64, f64)], what: &str) {
    assert_eq!(a.len(), b.len(), "{what}: {a:?} vs {b:?}");
    for (x, y) in a.iter().zip(b) {
        near(x.0, y.0, 1e-9, what);
        near(x.1, y.1, 1e-9, what);
    }
}

/// The fixture tool's `voiceTake`: 16 kHz, a 50 Hz hum, a 220 Hz tone with
/// two overtones inside each burst.
fn voice_take(bursts: &[(f64, f64)], hum: f64, seconds: f64) -> Vec<f32> {
    let rate = 16_000.0;
    let count = (rate * seconds) as usize;
    let pi = std::f64::consts::PI;
    (0..count)
        .map(|i| {
            let t = i as f64 / rate;
            let mut v = hum * (2.0 * pi * 50.0 * t).sin();
            if bursts.iter().any(|b| t >= b.0 && t < b.1) {
                v += 0.2 * ((2.0 * pi * 220.0 * t).sin() + 0.5 * (2.0 * pi * 440.0 * t).sin() + 0.25 * (2.0 * pi * 660.0 * t).sin()) / 1.75;
            }
            v as f32
        })
        .collect()
}

#[test]
fn voice_by_level() {
    let fx = fixture("music_fit.json");
    for q in arr(&fx["voice"]) {
        let bursts = ranges(&q["bursts"]);
        let s = voice_take(&bursts, f(&q["hum"]), f(&q["seconds"]));
        let lv = voice::levels(&s, 16_000.0);
        let want: Vec<f64> = arr(&q["levels"]).iter().map(f).collect();
        assert_eq!(lv.len(), want.len(), "level frames");
        for (a, b) in lv.iter().zip(&want) {
            near(*a, *b, 1e-6, "level");
        }
        near(voice::threshold(&want), f(&q["threshold"]), 1e-12, "threshold");
        same_ranges(&voice::ranges(&want), &ranges(&q["ranges"]), "voice ranges");
        same_ranges(&voice::ranges(&lv), &ranges(&q["ranges"]), "voice ranges from our own levels");
    }
    for q in arr(&fx["levels"]) {
        let lv: Vec<f64> = arr(&q["levels"]).iter().map(f).collect();
        near(voice::threshold(&lv), f(&q["threshold"]), 1e-12, "threshold");
        same_ranges(&voice::ranges(&lv), &ranges(&q["ranges"]), "ranges");
    }
}

#[test]
fn fit_and_outro() {
    let fx = fixture("music_fit.json");
    let grids: Vec<Option<MusicGrid>> = arr(&fx["grids"]).iter().map(|g| serde_json::from_value(g.clone()).unwrap()).collect();
    for q in arr(&fx["fit"]) {
        let g = grids[q["grid"].as_u64().unwrap() as usize].as_ref();
        let (song, length) = (f(&q["song"]), f(&q["length"]));
        let (offset, outro) = music_fit::place(g, song, length, q["from"].as_f64(), q["punchy"].as_bool().unwrap());
        near(offset, f(&q["offset"]), 1e-9, &format!("offset {q}"));
        near(outro, f(&q["outro"]), 1e-9, &format!("outro {q}"));
        for o in arr(&q["outros"]) {
            near(music_fit::outro(g, f(&o[0]), length), f(&o[1]), 1e-9, &format!("outro at {o} {q}"));
        }
    }
}

#[test]
fn suggestions_and_tempo() {
    let fx = fixture("music_fit.json");
    let songs: Vec<Song> = serde_json::from_str(fx["songs"].as_str().unwrap()).unwrap();
    for q in arr(&fx["suggest"]) {
        let favs: HashSet<String> = arr(&q["favourites"]).iter().map(|v| v.as_str().unwrap().to_string()).collect();
        let (length, mood, vertical) = (f(&q["length"]), q["mood"].as_str(), q["vertical"].as_bool().unwrap());
        let got: Vec<&str> = music_fit::suggest(&songs, length, mood, vertical, &favs, 4).iter().map(|s| s.id.as_str()).collect();
        let want: Vec<&str> = arr(&q["ids"]).iter().map(|v| v.as_str().unwrap()).collect();
        assert_eq!(got, want, "suggest {q}");
        for (s, w) in songs.iter().zip(arr(&q["scores"])) {
            near(music_fit::suggest_score(s, length, mood, vertical, favs.contains(&s.id)), f(w), 1e-12, "score");
        }
    }
    // tempo: the made-up songs, then the bundled library's
    let folder = repo().join("Resources/Music");
    let lib = music::parse_library(&std::fs::read(folder.join("library.json")).unwrap(), &folder).unwrap();
    for q in arr(&fx["tempo"]) {
        let id = q["id"].as_str().unwrap();
        let s = songs.iter().find(|s| s.id == id).or_else(|| lib.iter().find(|s| s.id == id)).unwrap_or_else(|| panic!("song {id}"));
        assert_eq!(music_fit::tempo(s), q["tempo"].as_str(), "tempo of {id}");
    }
    // every library track carries its fit
    for s in &lib {
        assert!(s.energy.is_some() && s.peaks.as_ref().is_some_and(|p| p.len() >= 32), "{} has energy and peaks", s.id);
        assert!(!s.needs_credit(), "{} is CC0 or public domain", s.id);
    }
}
