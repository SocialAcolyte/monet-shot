//! The Swift MonetShotKit's answers (`shared/fixtures`, made by
//! `shared/tools/fixtures.sh`) must be ours too. When the Mac changes
//! behaviour: regenerate, watch these go red, port until green.

use monetshot_core::camera::{self as camera_mod, music_envelope};
use monetshot_core::camera_math::{self, segment_edits, Camera, SmoothTrack};
use monetshot_core::json::{from_json, to_swift_json};
use monetshot_core::music::{self, MusicGrid, Song};
use monetshot_core::plan::{PlanTake, Planner};
use monetshot_core::timemap::{clip_edits, TimeMap};
use monetshot_core::*;
use serde_json::Value;
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
fn i(v: &Value) -> i64 {
    v.as_i64().unwrap_or_else(|| panic!("not an int: {v}"))
}
fn arr(v: &Value) -> &Vec<Value> {
    v.as_array().unwrap_or_else(|| panic!("not an array: {v}"))
}

/// Equal to the last few bits (the Mac and this share IEEE doubles; libm
/// may differ by an ulp on other systems).
#[track_caller]
fn near(a: f64, b: f64, what: &str) {
    let tol = 1e-9 * (1.0 + a.abs().max(b.abs()));
    assert!((a - b).abs() <= tol, "{what}: rust {a} vs mac {b}");
}

#[track_caller]
fn near_tol(a: f64, b: f64, tol: f64, what: &str) {
    assert!((a - b).abs() <= tol, "{what}: rust {a} vs mac {b}");
}

fn clip(v: &Value) -> Clip {
    let mut c = Clip::new(f(&v["start"]), f(&v["end"]), i(&v["take"]));
    c.speed = v.get("speed").map_or(1.0, f);
    c.fade_in = v.get("fadeIn").map_or(0.0, f);
    c.fade_out = v.get("fadeOut").map_or(0.0, f);
    c
}
fn clips(v: &Value) -> Vec<Clip> {
    arr(v).iter().map(clip).collect()
}
#[track_caller]
fn same_clips(a: &[Clip], b: &Value, what: &str) {
    let b = clips(b);
    assert_eq!(a.len(), b.len(), "{what}: {a:?} vs {b:?}");
    for (x, y) in a.iter().zip(&b) {
        near(x.start, y.start, what);
        near(x.end, y.end, what);
        assert_eq!(x.take, y.take, "{what}");
        near(x.speed, y.speed, what);
        near(x.fade_in, y.fade_in, what);
        near(x.fade_out, y.fade_out, what);
    }
}
fn sample(v: &Value) -> CursorSample {
    CursorSample::new(f(&v["t"]), f(&v["x"]), f(&v["y"]))
}
fn samples(v: &Value) -> Vec<CursorSample> {
    arr(v).iter().map(sample).collect()
}
fn seg(v: &Value) -> ZoomSegment {
    let mut s = ZoomSegment::new(f(&v["start"]), f(&v["end"]), f(&v["scale"]), v["auto"].as_bool().unwrap(), i(&v["take"]));
    s.focus_x = v["focusX"].as_f64();
    s.focus_y = v["focusY"].as_f64();
    s
}
fn segs(v: &Value) -> Vec<ZoomSegment> {
    arr(v).iter().map(seg).collect()
}
#[track_caller]
fn same_seg(a: &ZoomSegment, b: &Value, what: &str) {
    let b = seg(b);
    near(a.start, b.start, what);
    near(a.end, b.end, what);
    near(a.scale, b.scale, what);
    assert_eq!((a.auto, a.take, a.focus_x.is_some(), a.focus_y.is_some()), (b.auto, b.take, b.focus_x.is_some(), b.focus_y.is_some()), "{what}");
}
#[track_caller]
fn same_segs(a: &[ZoomSegment], b: &Value, what: &str) {
    assert_eq!(a.len(), arr(b).len(), "{what}: count");
    for (x, y) in a.iter().zip(arr(b)) {
        same_seg(x, y, what);
    }
}
fn rect(v: &Value) -> NormRect {
    NormRect::new(f(&v["x"]), f(&v["y"]), f(&v["w"]), f(&v["h"]))
}
#[track_caller]
fn same_rect(a: NormRect, b: &Value, what: &str) {
    let b = rect(b);
    near(a.x, b.x, what);
    near(a.y, b.y, what);
    near(a.w, b.w, what);
    near(a.h, b.h, what);
}
fn pair(v: &Value) -> (f64, f64) {
    (f(&v[0]), f(&v[1]))
}
#[track_caller]
fn same_camera(a: Camera, b: &Value, what: &str) {
    near(a.scale, f(&b["scale"]), what);
    near(a.center_x, f(&b["centerX"]), what);
    near(a.center_y, f(&b["centerY"]), what);
    near(a.window, b.get("window").map_or(1.0, f), what);
}
fn edit(v: &Value) -> EditDoc {
    from_json(v.as_str().unwrap().as_bytes()).unwrap()
}

#[test]
fn timemap() {
    for c in arr(&fixture("timemap.json")["cases"]) {
        let m = TimeMap::from_clips(&clips(&c["clips"]));
        near(m.duration(), f(&c["duration"]), "duration");
        assert_eq!(m.spans.len(), arr(&c["spans"]).len());
        for (s, w) in m.spans.iter().zip(arr(&c["spans"])) {
            assert_eq!(s.take, i(&w["take"]));
            near(s.at, f(&w["at"]), "span at");
        }
        for q in arr(&c["locate"]) {
            let l = m.locate(f(&q["t"]));
            assert_eq!((l.index as i64, l.take), (i(&q["index"]), i(&q["take"])), "locate {}", q["t"]);
            near(l.time, f(&q["time"]), "locate time");
        }
        for q in arr(&c["output"]) {
            let o = m.output(i(&q["take"]), f(&q["time"]));
            assert_eq!(o.is_some(), !q["output"].is_null(), "output {q}");
            if let Some(o) = o {
                near(o, f(&q["output"]), "output");
            }
            assert_eq!(m.keeps(i(&q["take"]), f(&q["time"])), q["keeps"].as_bool().unwrap());
        }
    }
}

#[test]
fn kept_clips() {
    for c in arr(&fixture("kept_clips.json")["cases"]) {
        let doc = edit(&c["edit"]);
        same_clips(&doc.kept_clips(f(&c["duration"])), &c["clips"], "kept clips");
    }
}

#[test]
fn canvas() {
    for c in arr(&fixture("canvas.json")["cases"]) {
        let mut doc = EditDoc::default();
        doc.output_width = i(&c["outputWidth"]);
        doc.canvas_aspect = f(&c["canvasAspect"]);
        let s = doc.canvas_size(f(&c["recordingAspect"]));
        assert_eq!(s, (i(&c["width"]), i(&c["height"])), "{c}");
    }
}

#[test]
fn clip_edits() {
    for c in arr(&fixture("clip_edits.json")["cases"]) {
        let list = clips(&c["clips"]);
        let st = clip_edits::starts(&list);
        for (a, b) in st.iter().zip(arr(&c["starts"])) {
            near(*a, f(b), "starts");
        }
        for q in arr(&c["split"]) {
            let r = clip_edits::split(&list, f(&q["t"]));
            assert_eq!(r.is_some(), !q["result"].is_null(), "split at {}", q["t"]);
            if let Some(r) = r {
                same_clips(&r, &q["result"], "split");
            }
        }
        for q in arr(&c["delete"]) {
            same_clips(&clip_edits::delete(&list, i(&q["i"])), &q["result"], "delete");
        }
        for q in arr(&c["resize"]) {
            let r = clip_edits::resize(&list, i(&q["i"]), q["leading"].as_bool().unwrap(), f(&q["to"]), f(&q["takeDuration"]));
            same_clips(&r, &q["result"], "resize");
        }
        for q in arr(&c["move"]) {
            same_clips(&clip_edits::move_clip(&list, i(&q["from"]), i(&q["to"])), &q["result"], "move");
        }
        for q in arr(&c["dropIndex"]) {
            assert_eq!(clip_edits::drop_index(&list, i(&q["dragging"]), f(&q["centreAt"])), i(&q["result"]), "dropIndex {q}");
        }
    }
}

#[test]
fn clip_speed_and_fades() {
    for c in arr(&fixture("clip_speed.json")["cases"]) {
        let list = clips(&c["clips"]);
        let m = TimeMap::from_clips(&list);
        near(m.duration(), f(&c["duration"]), "duration");
        assert_eq!(m.spans.len(), arr(&c["spans"]).len());
        for (s, w) in m.spans.iter().zip(arr(&c["spans"])) {
            assert_eq!(s.take, i(&w["take"]));
            near(s.at, f(&w["at"]), "span at");
            near(s.speed, f(&w["speed"]), "span speed");
            near(s.fade_in, f(&w["fadeIn"]), "span fade in");
            near(s.fade_out, f(&w["fadeOut"]), "span fade out");
        }
        for (a, b) in clip_edits::starts(&list).iter().zip(arr(&c["starts"])) {
            near(*a, f(b), "starts");
        }
        for q in arr(&c["locate"]) {
            let l = m.locate(f(&q["t"]));
            assert_eq!((l.index as i64, l.take), (i(&q["index"]), i(&q["take"])), "locate {}", q["t"]);
            near(l.time, f(&q["time"]), "locate time");
            near(m.presence(f(&q["t"])), f(&q["presence"]), "presence");
        }
        for q in arr(&c["output"]) {
            let o = m.output(i(&q["take"]), f(&q["time"]));
            assert_eq!(o.is_some(), !q["output"].is_null(), "output {q}");
            if let Some(o) = o {
                near(o, f(&q["output"]), "output");
            }
        }
        for q in arr(&c["split"]) {
            let r = clip_edits::split(&list, f(&q["t"]));
            assert_eq!(r.is_some(), !q["result"].is_null(), "split at {}", q["t"]);
            if let Some(r) = r {
                same_clips(&r, &q["result"], "split");
            }
        }
        for q in arr(&c["dropIndex"]) {
            assert_eq!(clip_edits::drop_index(&list, i(&q["dragging"]), f(&q["centreAt"])), i(&q["result"]), "dropIndex {q}");
        }
        for q in arr(&c["setSpeed"]) {
            same_clips(&clip_edits::set_speed(&list, i(&q["i"]), f(&q["speed"])), &q["result"], "setSpeed");
        }
    }
}

#[test]
fn text_overlays() {
    let fx = fixture("text.json");
    for c in arr(&fx["cases"]) {
        let o: TextOverlay = from_json(c["overlay"].as_str().unwrap().as_bytes()).unwrap();
        assert_eq!(o.has_backing(), c["backing"].as_bool().unwrap(), "backing {o:?}");
        // The overlay re-encodes to the Mac's exact bytes.
        assert_eq!(to_swift_json(&o).unwrap(), c["overlay"].as_str().unwrap(), "overlay json");
        let (w, h) = (f(&c["width"]), f(&c["height"]));
        for q in arr(&c["states"]) {
            let t = f(&q["t"]);
            let st = text_motion::state(&o, t, w, h);
            assert_eq!(st.is_some(), q.get("state").is_none(), "shown at {t} {o:?}");
            let Some(st) = st else { continue };
            let lines: Vec<&str> = arr(&q["lines"]).iter().map(|l| l.as_str().unwrap()).collect();
            assert_eq!(st.lines, lines, "lines");
            for (a, k) in [(st.px, "px"), (st.tracking, "tracking"), (st.center_x, "centerX"), (st.center_y, "centerY"), (st.opacity, "opacity"), (st.scale, "scale")] {
                near(a, f(&q[k]), &format!("{k} at {t}"));
            }
            assert_eq!(st.words.len(), arr(&q["words"]).len(), "word count");
            for (a, b) in st.words.iter().zip(arr(&q["words"])) {
                near(*a, f(b), "word alpha");
            }
        }
    }
    for e in arr(&fx["edits"]) {
        let len = f(&e["videoLength"]);
        let span = |o: &TextOverlay, v: &Value, what: &str| {
            near(o.at, f(&v["at"]), what);
            near(o.duration, f(&v["duration"]), what);
        };
        let o = text_edits::insert("x", TextStyle::Caption, TextAnimation::Fade, f(&e["at"]), len, f(&e["duration"]));
        span(&o, &e["inserted"], "insert");
        span(&text_edits::move_to(&o, f(&e["moveTo"]), len), &e["moved"], "move");
        span(&text_edits::resize(&o, true, f(&e["leadTo"]), len), &e["lead"], "resize leading");
        span(&text_edits::resize(&o, false, f(&e["trailTo"]), len), &e["trail"], "resize trailing");
    }
    let doc: EditDoc = from_json(fx["edit"].as_str().unwrap().as_bytes()).unwrap();
    assert_eq!(doc.overlays().len(), 1);
    assert_eq!(doc.format.as_deref(), Some("fast"));
    assert_eq!(to_swift_json(&doc).unwrap(), fx["edit"].as_str().unwrap(), "edit with texts and a format");
}

#[test]
fn formats() {
    let fx = fixture("formats.json");
    let ours = monetshot_core::formats::all();
    assert_eq!(ours.len(), arr(&fx["formats"]).len());
    for (fm, m) in ours.iter().zip(arr(&fx["formats"])) {
        assert_eq!((fm.id, fm.name, fm.blurb, fm.music_mood), (m["id"].as_str().unwrap(), m["name"].as_str().unwrap(), m["blurb"].as_str().unwrap(), m["musicMood"].as_str().unwrap()));
        near(fm.speed, f(&m["speed"]), "format speed");
    }
    for c in arr(&fx["cases"]) {
        let fm = monetshot_core::formats::named(c["format"].as_str().unwrap()).unwrap();
        let out = fm.apply(&edit(&c["edit"]), f(&c["duration"]));
        assert_eq!(to_swift_json(&out).unwrap(), c["result"].as_str().unwrap(), "{} applied", fm.id);
    }
}

#[test]
fn smooth_track() {
    let fx = fixture("smooth.json");
    for c in arr(&fx["cases"]) {
        let tr = SmoothTrack::make(&samples(&c["samples"]), f(&c["duration"]), f(&c["omega"]));
        assert_eq!(tr.xs.len(), arr(&c["xs"]).len());
        for (k, (a, b)) in tr.xs.iter().zip(arr(&c["xs"])).enumerate() {
            near(*a, f(b), &format!("xs[{k}] omega {}", c["omega"]));
        }
        for (a, b) in tr.ys.iter().zip(arr(&c["ys"])) {
            near(*a, f(b), "ys");
        }
        for q in arr(&c["positions"]) {
            let p = tr.position(f(&q["t"]));
            near(p.0, f(&q["x"]), "position x");
            near(p.1, f(&q["y"]), "position y");
        }
    }
    for q in arr(&fx["cursorOmega"]) {
        near(camera_math::cursor_omega(f(&q["smoothing"])), f(&q["omega"]), "cursorOmega");
    }
}

#[test]
fn camera() {
    let fx = fixture("camera.json");
    for c in arr(&fx["cases"]) {
        let ss = segs(&c["segments"]);
        let focus = SmoothTrack::make(&samples(&c["samples"]), f(&c["duration"]), camera_math::CAMERA_OMEGA);
        for q in arr(&c["queries"]) {
            let t = f(&q["t"]);
            same_camera(camera_math::camera_at(t, &ss, &focus), &q["camera"], &format!("camera at {t}"));
            for (s, w) in ss.iter().zip(arr(&q["weights"])) {
                near(camera_math::weight(s, t), f(w), "weight");
            }
        }
    }
    for q in arr(&fx["ease"]) {
        near(camera_math::ease(f(&q["u"])), f(&q["ease"]), "ease");
    }
    for q in arr(&fx["viewport"]) {
        let c = Camera::new(f(&q["camera"]["scale"]), f(&q["camera"]["centerX"]), f(&q["camera"]["centerY"]));
        let v = c.viewport();
        for (a, b) in [v.0, v.1, v.2, v.3].iter().zip(arr(&q["viewport"])) {
            near(*a, f(b), "viewport");
        }
        let p = c.project(0.3, 0.8);
        near(p.0, f(&q["project"][0]), "project");
        near(p.1, f(&q["project"][1]), "project");
    }
}

#[test]
fn auto_zooms() {
    for c in arr(&fixture("auto_zooms.json")["cases"]) {
        let clicks = samples(&c["clicks"]);
        let d = f(&c["duration"]);
        same_segs(&camera_math::auto_zooms(&clicks, d), &c["segments"], "autoZooms");
        same_segs(&camera_math::auto_zooms_with(&clicks, d, 3.0, 2), &c["scale3take2"], "autoZooms scale 3 take 2");
    }
}

#[test]
fn segment_edits() {
    let fx = fixture("segment_edits.json");
    for q in arr(&fx["move"]) {
        same_seg(&segment_edits::move_by(&seg(&q["segment"]), f(&q["delta"]), f(&q["duration"])), &q["result"], "move");
    }
    for q in arr(&fx["resize"]) {
        let r = segment_edits::resize(&seg(&q["segment"]), q["leading"].as_bool().unwrap(), f(&q["to"]), f(&q["duration"]));
        same_seg(&r, &q["result"], "resize");
    }
    for q in arr(&fx["insert"]) {
        let r = segment_edits::insert(f(&q["at"]), &segs(&q["segments"]), f(&q["duration"]), f(&q["length"]), i(&q["take"]));
        assert_eq!(r.is_some(), !q["result"].is_null(), "insert {q}");
        if let Some(r) = r {
            same_seg(&r, &q["result"], "insert");
        }
    }
    for q in arr(&fx["reAuto"]) {
        let r = segment_edits::re_auto(&segs(&q["segments"]), &samples(&q["clicks"]), f(&q["duration"]), i(&q["take"]));
        same_segs(&r, &q["result"], "reAuto");
    }
}

#[test]
fn ripples_and_press() {
    let fx = fixture("ripples.json");
    let clicks = samples(&fx["clicks"]);
    for q in arr(&fx["cases"]) {
        let t = f(&q["t"]);
        for (key, dur) in [("ripples", camera_math::RIPPLE_DURATION), ("ripples02", 0.2)] {
            let r = camera_math::ripples(&clicks, t, dur);
            assert_eq!(r.len(), arr(&q[key]).len(), "{key} at {t}");
            for (a, b) in r.iter().zip(arr(&q[key])) {
                near(a.0.t, f(&b["click"]["t"]), "ripple click");
                near(a.1, f(&b["progress"]), "ripple progress");
            }
        }
        near(camera_math::press_scale(&clicks, t), f(&q["pressScale"]), "pressScale");
    }
}

#[test]
fn norm_rect() {
    let fx = fixture("normrect.json");
    for c in arr(&fx["cases"]) {
        let r = rect(&c["rect"]);
        assert_eq!(r.is_full(), c["isFull"].as_bool().unwrap());
        same_rect(r.clamped(0.02), &c["clamped"], "clamped");
        same_rect(r.clamped(0.1), &c["clamped01"], "clamped 0.1");
        let (px, py) = pair(&c["point"]);
        let l = r.local(px, py);
        near(l.0, f(&c["local"][0]), "local");
        near(l.1, f(&c["local"][1]), "local");
        let g = r.global(px, py);
        near(g.0, f(&c["global"][0]), "global");
        near(g.1, f(&c["global"][1]), "global");
        let (dx, dy) = (f(&c["dx"]), f(&c["dy"]));
        same_rect(r.moved(dx, dy), &c["moved"], "moved");
        let (hx, hy) = (f(&c["hx"]), f(&c["hy"]));
        same_rect(r.resized(hx, hy, dx, dy, 0.02), &c["resized"], "resized");
        same_rect(r.resized(hx, hy, dx, dy, 0.05), &c["resized05"], "resized 0.05");
        same_rect(NormRect::spanning(pair(&c["a"]), pair(&c["b"])), &c["spanning"], "spanning");
    }
    for c in arr(&fx["setCrop"]) {
        let mut doc = EditDoc::default();
        doc.set_crop(NormRect::new(0.1, 0.1, 0.3, 0.3), 1);
        doc.set_crop(rect(&c["set"]), 0);
        assert_eq!(doc.crops.len(), arr(&c["crops"]).len());
        for (a, b) in doc.crops.iter().zip(arr(&c["crops"])) {
            assert_eq!(a.take, i(&b["take"]));
            same_rect(a.rect, &b["rect"], "crop");
        }
        same_rect(doc.crop(0), &c["crop0"], "crop 0");
        same_rect(doc.crop(2), &c["crop2"], "crop 2");
    }
}

#[test]
fn camera_clips_and_music_envelope() {
    let fx = fixture("camera_clips.json");
    let cc = |v: &Value| CameraClip::new(v["file"].as_str().unwrap(), f(&v["at"]), f(&v["duration"]), v["full"].as_bool().unwrap());
    for q in arr(&fx["insert"]) {
        let list: Vec<CameraClip> = arr(&q["clips"]).iter().map(cc).collect();
        let r = camera_mod::insert(cc(&q["clip"]), &list);
        let want: Vec<CameraClip> = arr(&q["result"]).iter().map(cc).collect();
        assert_eq!(r.len(), want.len());
        for (a, b) in r.iter().zip(&want) {
            assert_eq!((&a.file, a.full), (&b.file, b.full));
            near(a.at, b.at, "camera clip at");
            near(a.duration, b.duration, "camera clip duration");
        }
    }
    for q in arr(&fx["presence"]) {
        near(camera_mod::presence(&cc(&q["clip"]), f(&q["t"])), f(&q["presence"]), "presence");
    }
    for q in arr(&fixture("music_envelope.json")["cases"]) {
        let voice: Vec<(f64, f64)> = arr(&q["voice"]).iter().map(pair).collect();
        let g = music_envelope::gain_with(f(&q["t"]), f(&q["length"]), q["fadeIn"].as_bool().unwrap(), q["fadeOut"].as_bool().unwrap(), q["outro"].as_f64(), &voice);
        near(g, f(&q["gain"]), &format!("gain {q}"));
    }
}

#[test]
fn music() {
    let fx = fixture("music.json");
    for q in arr(&fx["stableID"]) {
        assert_eq!(music::stable_id(q["id"].as_str().unwrap()), q["stableID"].as_str().unwrap());
    }
    for q in arr(&fx["licenses"]) {
        let s: Song = serde_json::from_value(serde_json::json!({
            "id": "x", "title": "T", "artist": "A", "duration": 1, "genres": [], "license": q["license"],
            "licenseVersion": q["licenseVersion"], "audioURL": "x.m4a"
        }))
        .unwrap();
        assert_eq!(s.license_label(), q["label"].as_str().unwrap());
        assert_eq!(s.needs_credit(), q["needsCredit"].as_bool().unwrap());
    }
    // Searches run over the bundled library, part of the Mac's music work
    // (shared/PENDING); without it there is nothing to search.
    let folder = repo().join("Resources/Music");
    match std::fs::read(folder.join("library.json")) {
        Ok(data) => {
            let lib = music::parse_library(&data, &folder).unwrap();
            for q in arr(&fx["search"]) {
                let found: Vec<&str> = music::search(&lib, q["query"].as_str().unwrap(), q["mood"].as_str()).iter().map(|s| s.id.as_str()).collect();
                let want: Vec<&str> = arr(&q["ids"]).iter().map(|v| v.as_str().unwrap()).collect();
                assert_eq!(found, want, "search {q}");
            }
        }
        Err(_) => eprintln!("skipped searches: no Resources/Music/library.json in this checkout"),
    }
    for q in arr(&fx["grid"]) {
        let s = synth_song(f(&q["bpm"]), f(&q["start"]), i(&q["quietBars"]) as usize, f(&q["seconds"]));
        let g = MusicGrid::analyze(&s, 11_025.0);
        if q["grid"].is_null() {
            assert!(g.is_none(), "no grid for {q}");
            continue;
        }
        let g = g.unwrap_or_else(|| panic!("a grid for {}", q["bpm"]));
        let w = &q["grid"];
        near_tol(g.bar, f(&w["bar"]), 1e-6, "bar");
        near_tol(g.first_downbeat, f(&w["firstDownbeat"]), 1e-6, "first downbeat");
        assert_eq!(g.lifts.len(), arr(&w["lifts"]).len(), "lifts {:?} vs {}", g.lifts, w["lifts"]);
        for (a, b) in g.lifts.iter().zip(arr(&w["lifts"])) {
            near_tol(*a, f(b), 1e-6, "lift");
        }
        for p in arr(&w["nearest"]) {
            near_tol(g.nearest_bar_line(f(&p[0])), f(&p[1]), 1e-6, "nearest bar line");
        }
    }
}

/// The same synthetic song as the fixture tool's `synthSong`.
fn synth_song(bpm: f64, start: f64, quiet_bars: usize, seconds: f64) -> Vec<f32> {
    let rate = 11_025.0;
    let beat = 60.0 / bpm;
    let count = (rate * seconds) as usize;
    let mut s = vec![0f32; count];
    let (mut k, mut t) = (0usize, start);
    let mut noise: u32 = 12345;
    while t < seconds {
        let loud: f32 = if t < start + quiet_bars as f64 * beat * 4.0 { 0.25 } else { 0.8 };
        let hit: f32 = (if k % 4 == 0 { 1.0 } else { 0.45 }) * loud;
        let i0 = (t * rate) as usize;
        for i in 0..(rate * 0.12) as usize {
            if i0 + i < count {
                s[i0 + i] += hit * ((i as f64 * 0.35).sin() as f32) * ((-(i as f64) / (rate * 0.03)).exp() as f32);
            }
        }
        let h0 = ((t + beat / 2.0) * rate) as usize;
        for i in 0..(rate * 0.02) as usize {
            if h0 + i < count {
                noise = noise.wrapping_mul(1_103_515_245).wrapping_add(12345);
                s[h0 + i] += 0.08 * loud * (((noise >> 16) & 0x7FFF) as f32 / 16383.5 - 1.0);
            }
        }
        k += 1;
        t += beat;
    }
    s
}

#[test]
fn json_like_the_mac() {
    for c in arr(&fixture("json.json")["cases"]) {
        let input = c["input"].as_str().unwrap().as_bytes();
        let note = c["note"].as_str().unwrap();
        let ours: Option<String> = match c["type"].as_str().unwrap() {
            "edit" => from_json::<EditDoc>(input).ok().map(|v| to_swift_json(&v).unwrap()),
            "meta" => from_json::<RecordingMeta>(input).ok().map(|v| to_swift_json(&v).unwrap()),
            _ => from_json::<CursorTrack>(input).ok().map(|v| to_swift_json(&v).unwrap()),
        };
        match (&ours, c["output"].as_str()) {
            (Some(a), Some(b)) => assert_eq!(a, b, "{note}"),
            (None, None) => {}
            // Where the desktop is deliberately more forgiving than the Mac.
            (Some(_), None) if note.contains("desktop keeps") || note.contains("Mac refuses") => {}
            _ => panic!("{note}: rust {ours:?} vs mac {}", c["output"]),
        }
    }
}

#[test]
fn unknown_keys_and_values_survive() {
    let input = r#"{"backdrop":"neon","future":{"b":[1,2.5]},"segments":[{"id":"E66CDC53-D527-48B9-B32E-9E7FD7751E19","start":1,"end":2,"scale":2,"wobble":0.5}]}"#;
    let doc: EditDoc = from_json(input.as_bytes()).unwrap();
    assert_eq!(doc.backdrop, Backdrop::Other("neon".into()));
    assert_eq!(doc.backdrop.known(), Backdrop::Paper);
    let out = to_swift_json(&doc).unwrap();
    assert!(out.contains("\"backdrop\" : \"neon\""), "{out}");
    assert!(out.contains("\"future\" : {"), "{out}");
    assert!(out.contains("\"wobble\" : 0.5"), "{out}");
    let back: EditDoc = from_json(out.as_bytes()).unwrap();
    assert_eq!(back, doc);
}

#[test]
fn frame_layout() {
    for c in arr(&fixture("layout.json")["cases"]) {
        let name = c["name"].as_str().unwrap();
        let doc = edit(&c["edit"]);
        let takes: Vec<PlanTake> = arr(&c["takes"])
            .iter()
            .map(|t| PlanTake {
                meta: from_json(t["meta"].as_str().unwrap().as_bytes()).unwrap(),
                cursor: from_json(t["cursor"].as_str().unwrap().as_bytes()).unwrap(),
                dir: String::new(),
            })
            .collect();
        let p = Planner::new(&doc, &takes);
        assert_eq!((p.canvas.width as f64, p.canvas.height as f64), pair(&c["canvas"]), "{name} canvas");
        assert_eq!(p.cursor_art_height as f64, f(&c["cursorArtHeight"]), "{name} art height");
        let b = p.bubble_rect();
        let wb = &c["bubbleRect"];
        assert_eq!((b.x, b.y, b.w, b.h), (f(&wb["x"]), f(&wb["y"]), f(&wb["w"]), f(&wb["h"])), "{name} bubble");
        near(p.duration(), f(&c["duration"]), "duration");
        for (k, l) in arr(&c["looks"]).iter().enumerate() {
            let fr = p.frame_rect(k as i64);
            let w = &l["frame"];
            assert_eq!((fr.x, fr.y, fr.w, fr.h), (f(&w["x"]), f(&w["y"]), f(&w["w"]), f(&w["h"])), "{name} frame {k}");
            same_rect(p.crop(k as i64), &l["crop"], "crop");
        }
        for q in arr(&c["frames"]) {
            let t = f(&q["t"]);
            let what = format!("{name} at {t}");
            let plan = p.plan(t);
            assert_eq!((plan.clip_index as i64, plan.take), (i(&q["index"]), i(&q["take"])), "{what}");
            near(plan.take_time, f(&q["time"]), &what);
            same_camera(plan.camera, &q["camera"], &what);
            match (&plan.cursor, q.get("cursorTip")) {
                (Some(cur), Some(tip)) => {
                    near(cur.tip.x, f(&tip[0]), &format!("{what} tip x"));
                    near(cur.tip.y, f(&tip[1]), &format!("{what} tip y"));
                    near(cur.height, f(&q["cursorHeight"]), &format!("{what} cursor height"));
                    assert_eq!(plan.ripples.len(), arr(&q["ripples"]).len(), "{what} ripples");
                    for (a, b) in plan.ripples.iter().zip(arr(&q["ripples"])) {
                        near(a.center.x, f(&b["center"][0]), &what);
                        near(a.center.y, f(&b["center"][1]), &what);
                        near(a.radius, f(&b["radius"]), &what);
                        near(a.alpha, f(&b["alpha"]), &what);
                    }
                }
                (None, None) => assert!(plan.ripples.is_empty()),
                _ => panic!("{what}: cursor {:?} vs {:?}", plan.cursor, q.get("cursorTip")),
            }
        }
    }
}

#[test]
fn captions() {
    use monetshot_core::captions::{self, Transcript};
    use monetshot_core::vertical::safe_area;
    let fx = fixture("captions.json");
    let transcript = |v: &Value| -> Option<Transcript> { v.as_str().map(|s| from_json(s.as_bytes()).unwrap()) };
    for (n, c) in arr(&fx["cases"]).iter().enumerate() {
        let trs: Vec<Option<Transcript>> = arr(&c["transcripts"]).iter().map(transcript).collect();
        for (t, v) in trs.iter().zip(arr(&c["transcripts"])) {
            if let Some(t) = t {
                assert_eq!(to_swift_json(t).unwrap(), v.as_str().unwrap(), "transcript json");
            }
        }
        let doc = edit(&c["edit"]);
        let map = TimeMap::new(&doc, f(&c["takeDuration"]));
        let (w, h) = (f(&c["width"]), f(&c["height"]));
        let anim: TextAnimation = serde_json::from_value(c["animation"].clone()).unwrap();
        let words = captions::words(&trs, &map);
        assert_eq!(words.len(), arr(&c["words"]).len(), "case {n}: word count");
        for (a, b) in words.iter().zip(arr(&c["words"])) {
            assert_eq!(a.text, b["text"].as_str().unwrap());
            near(a.start, f(&b["start"]), "word start");
            near(a.end, f(&b["end"]), "word end");
            assert_eq!((a.span as i64, a.take, a.index as i64), (i(&b["span"]), i(&b["take"]), i(&b["index"])), "word place");
        }
        let overlays = captions::overlays(&trs, &map, w, h, anim);
        assert_eq!(overlays.len(), arr(&c["overlays"]).len(), "case {n}: phrase count");
        for (a, b) in overlays.iter().zip(arr(&c["overlays"])) {
            let mac: TextOverlay = from_json(b.as_str().unwrap().as_bytes()).unwrap();
            assert_eq!(a.text, mac.text, "case {n}: phrase");
            assert_eq!(a.id, mac.id);
            for (x, y, k) in [(a.at, mac.at, "at"), (a.duration, mac.duration, "duration"), (a.x, mac.x, "x"), (a.y, mac.y, "y"), (a.size, mac.size, "size")] {
                near(x, y, &format!("case {n}: {k}"));
            }
            assert_eq!(a.animation, mac.animation);
            let (ab, mb) = (a.beats.clone().unwrap(), mac.beats.clone().unwrap());
            assert_eq!(ab.len(), mb.len());
            for (x, y) in ab.iter().zip(&mb) {
                near(*x, *y, "beat");
            }
        }
        assert_eq!(captions::srt(&overlays), c["srt"].as_str().unwrap(), "case {n}: srt");
        assert_eq!(captions::text(&words), c["text"].as_str().unwrap(), "case {n}: text");
        let mut q = arr(&c["states"]).iter();
        for o in &overlays {
            let mut t = o.at - 0.05;
            while t < o.end() + 0.05 {
                if let Some(st) = text_motion::state(o, t, w, h) {
                    let m = q.next().expect("a state");
                    near(f(&m["t"]), t, "state t");
                    let lines: Vec<&str> = arr(&m["lines"]).iter().map(|l| l.as_str().unwrap()).collect();
                    assert_eq!(st.lines, lines);
                    for (a, k) in [(st.px, "px"), (st.center_x, "centerX"), (st.center_y, "centerY"), (st.opacity, "opacity"), (st.scale, "scale")] {
                        near(a, f(&m[k]), &format!("case {n}: {k} at {t}"));
                    }
                    assert_eq!(st.words.len(), arr(&m["words"]).len());
                    for (a, b) in st.words.iter().zip(arr(&m["words"])) {
                        near(*a, f(b), "word alpha");
                    }
                    assert_eq!(st.highlight.map(|x| x as i64), m["highlight"].as_i64(), "case {n}: highlight at {t}");
                }
                t += 0.11;
            }
        }
        assert!(q.next().is_none(), "case {n}: as many states as the Mac");
    }
    for l in arr(&fx["lines"]) {
        let ws: Vec<&str> = arr(&l["words"]).iter().map(|w| w.as_str().unwrap()).collect();
        assert_eq!(captions::lines(&ws), l["text"].as_str().unwrap());
    }
    let tr: Transcript = from_json(fx["transcript"].as_str().unwrap().as_bytes()).unwrap();
    for e in arr(&fx["edits"]) {
        let got = tr.editing(i(&e["index"]) as usize, e["text"].as_str().unwrap());
        assert_eq!(to_swift_json(&got).unwrap(), e["result"].as_str().unwrap(), "transcript edit");
    }
    let meta: RecordingMeta = from_json(fx["meta"].as_str().unwrap().as_bytes()).unwrap();
    assert_eq!((meta.voice.as_deref(), meta.voice_offset), (Some("voice.m4a"), Some(0.25)));
    assert_eq!(to_swift_json(&meta).unwrap(), fx["meta"].as_str().unwrap(), "meta with a voice");
    let doc = edit(&fx["edit"]);
    assert_eq!(doc.captions, Some(true));
    assert_eq!(to_swift_json(&doc).unwrap(), fx["edit"].as_str().unwrap(), "edit with captions");
    for s in arr(&fx["safeArea"]) {
        let r = safe_area(f(&s["width"]), f(&s["height"]));
        for (a, k) in [(r.x, "x"), (r.y, "y"), (r.w, "w"), (r.h, "h")] {
            near(a, f(&s[k]), "safe area");
        }
    }
}
