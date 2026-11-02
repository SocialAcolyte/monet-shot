//! `Sources/MonetShotChecks/main.swift`, the parts that are core's, as Rust
//! tests (the cursor art and renderer pixel checks live in monetshot-export;
//! Config/Store/Shell are the Mac app's own).

use monetshot_core::camera::{self as camera_mod, music_envelope};
use monetshot_core::camera_math::{self, segment_edits, Camera, SmoothTrack};
use monetshot_core::json::{from_json, to_swift_json, IsoDate};
use monetshot_core::music::{self, MusicChoice, MOODS};
use monetshot_core::plan::{PlanTake, Planner};
use monetshot_core::project::{take_folders, Take};
use monetshot_core::timemap::{clip_edits, TimeMap};
use monetshot_core::*;
use std::path::PathBuf;

fn near(a: f64, b: f64, eps: f64) -> bool {
    (a - b).abs() < eps
}

fn tmp(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("monetshot-core-checks-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn meta(w: i64, h: i64, scale: f64, duration: f64, source: &str, video: &str) -> RecordingMeta {
    RecordingMeta::new(w, h, scale, duration, IsoDate::now(), source, video)
}

#[test]
fn auto_zoom_groups_close_clicks_and_merges_near_spans() {
    let clicks = [CursorSample::new(2.0, 0.3, 0.3), CursorSample::new(3.0, 0.31, 0.3), CursorSample::new(12.0, 0.8, 0.7)];
    let segs = camera_math::auto_zooms(&clicks, 20.0);
    assert_eq!(segs.len(), 2);
    assert!(near(segs[0].start, 2.0 - camera_math::LEAD_IN, 1e-3));
    assert!(near(segs[0].end, 3.0 + camera_math::HOLD_AFTER, 1e-3));
    assert!(segs.iter().all(|s| s.auto));
    let close = camera_math::auto_zooms(&[CursorSample::new(2.0, 0.0, 0.0), CursorSample::new(5.8, 0.0, 0.0)], 20.0);
    assert_eq!(close.len(), 1);
    assert!(camera_math::auto_zooms(&[], 10.0).is_empty());
}

#[test]
fn zoom_weight_eases_in_holds_eases_out() {
    let s = ZoomSegment::new(1.0, 5.0, 2.0, false, 0);
    assert_eq!(camera_math::weight(&s, 0.5), 0.0);
    assert_eq!(camera_math::weight(&s, 3.0), 1.0);
    assert!(near(camera_math::weight(&s, 1.0 + camera_math::RAMP / 2.0), 0.5, 1e-3));
    assert_eq!(camera_math::weight(&s, 5.0), 0.0);
    let short = ZoomSegment::new(0.0, 0.6, 2.0, false, 0);
    assert_eq!(camera_math::weight(&short, 0.3), 1.0);
}

#[test]
fn camera_stays_inside_the_recording() {
    let track = SmoothTrack { xs: vec![0.02, 0.02], ys: vec![0.98, 0.98] };
    let seg = ZoomSegment::new(0.0, 10.0, 2.0, false, 0);
    let cam = camera_math::camera_at(5.0, &[seg.clone()], &track);
    assert!(near(cam.scale, 2.0, 1e-3));
    let v = cam.viewport();
    assert!(v.0 >= -1e-9 && v.1 >= -1e-9 && v.0 + v.2 <= 1.0 + 1e-9 && v.1 + v.3 <= 1.0 + 1e-9);
    assert_eq!(camera_math::camera_at(20.0, &[seg], &track), Camera::IDENTITY);
    let mut fixed = ZoomSegment::new(0.0, 10.0, 2.0, false, 0);
    fixed.focus_x = Some(0.5);
    fixed.focus_y = Some(0.5);
    let c2 = camera_math::camera_at(5.0, &[fixed], &track);
    assert!(near(c2.center_x, 0.5, 1e-3) && near(c2.center_y, 0.5, 1e-3));
}

#[test]
fn smoothed_cursor_has_no_lag_at_a_held_position() {
    let samples = [
        CursorSample::new(0.0, 0.1, 0.1),
        CursorSample::new(1.0, 0.1, 0.1),
        CursorSample::new(2.0, 0.9, 0.5),
        CursorSample::new(4.0, 0.9, 0.5),
    ];
    let track = SmoothTrack::make(&samples, 4.0, camera_math::cursor_omega(0.6));
    let p = track.position(3.0);
    assert!(near(p.0, 0.9, 0.01) && near(p.1, 0.5, 0.01));
    let mid = track.position(1.5);
    assert!(mid.0 > 0.3 && mid.0 < 0.7);
    assert!(near(track.position(0.0).0, 0.1, 0.02));
}

#[test]
fn segment_edits_stay_in_bounds_and_become_hand_made() {
    let s = ZoomSegment::new(2.0, 4.0, 2.0, true, 0);
    let moved = segment_edits::move_by(&s, 10.0, 6.0);
    assert!(near(moved.start, 4.0, 1e-3) && near(moved.end, 6.0, 1e-3));
    assert!(!moved.auto);
    let resized = segment_edits::resize(&s, true, 3.9, 6.0);
    assert!(near(resized.start, 4.0 - segment_edits::MIN_DURATION, 1e-3));
    assert!(segment_edits::insert(3.0, &[s.clone()], 6.0, 2.5, 0).is_none());
    let ins = segment_edits::insert(5.0, &[s], 6.0, 2.5, 0).unwrap();
    assert!(ins.start >= 4.0 && ins.end <= 6.0);
}

#[test]
fn re_running_auto_keeps_hand_made_zooms() {
    let manual = ZoomSegment::new(0.0, 3.0, 3.0, false, 0);
    let clicks = [CursorSample::new(1.0, 0.5, 0.5), CursorSample::new(10.0, 0.5, 0.5)];
    let out = segment_edits::re_auto(&[manual.clone()], &clicks, 20.0, 0);
    assert!(out.contains(&manual));
    assert_eq!(out.iter().filter(|s| s.auto).count(), 1);
}

#[test]
fn project_round_trips_and_canvas_sizes_are_even() {
    let dir = tmp("roundtrip");
    let folder = dir.join("a.reel");
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(folder.join("screen.mov"), b"").unwrap();
    let mut p = Project::new(
        folder.clone(),
        meta(2880, 1800, 2.0, 4.0, "display", "screen.mov"),
        CursorTrack { samples: vec![CursorSample::new(0.0, 0.5, 0.5)], ..Default::default() },
        EditDoc::default(),
    );
    p.edit.backdrop = Backdrop::Charcoal;
    p.save_meta().unwrap();
    p.save_cursor().unwrap();
    p.save_edit().unwrap();
    let back = Project::load(&folder).unwrap();
    assert_eq!(back.edit, p.edit);
    assert_eq!(back.meta(), p.meta());
    assert_eq!(back.cursor(), p.cursor());
    let mut doc = EditDoc::default();
    doc.output_width = 1921;
    doc.canvas_aspect = 0.0;
    assert_eq!(doc.canvas_size(16.0 / 10.0).1 % 2, 0);
    let old: EditDoc = from_json(br#"{"padding": 0.1}"#).unwrap();
    assert!(old.padding == 0.1 && old.backdrop == Backdrop::Paper);
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn planner_frames_the_recording_inside_the_canvas() {
    let takes = [PlanTake { meta: meta(2880, 1800, 2.0, 2.0, "display", "screen.mov"), cursor: CursorTrack::default(), dir: String::new() }];
    let p = Planner::new(&EditDoc::default(), &takes);
    assert_eq!((p.canvas.width, p.canvas.height), (2560, 1440));
    let f = p.frame_rect(0);
    assert!(f.x > 0.0 && f.y > 0.0 && f.max_x() < 2560.0 && f.max_y() < 1440.0);
    assert!((f.w / f.h - 1.6).abs() < 0.01);
}

#[test]
fn time_map_plays_clips_in_order_across_takes() {
    let m = TimeMap::from_clips(&[Clip::new(1.0, 3.0, 0), Clip::new(5.0, 9.0, 1), Clip::new(0.0, 1.0, 0)]);
    assert!(near(m.duration(), 7.0, 1e-3));
    let a = m.locate(2.5);
    assert!(a.index == 1 && a.take == 1 && near(a.time, 5.5, 1e-3));
    let b = m.locate(6.5);
    assert!(b.index == 2 && b.take == 0 && near(b.time, 0.5, 1e-3));
    assert_eq!(m.output(1, 6.0), Some(3.0));
    assert!(m.output(1, 2.0).is_none() && !m.keeps(0, 4.0));
    let mut doc = EditDoc::default();
    doc.cuts = vec![Cut::new(3.0, 5.0)];
    doc.trim_start = 1.0;
    doc.trim_end = Some(9.0);
    assert!(near(TimeMap::new(&doc, 10.0).duration(), 6.0, 1e-3));
}

#[test]
fn clip_edits_split_resize_delete_reorder() {
    let one = vec![Clip::new(0.0, 10.0, 0)];
    let two = clip_edits::split(&one, 4.0).unwrap();
    assert_eq!(two, vec![Clip::new(0.0, 4.0, 0), Clip::new(4.0, 10.0, 0)]);
    assert!(clip_edits::split(&two, 4.05).is_none());
    let shrunk = clip_edits::resize(&two, 0, false, 3.0, 10.0);
    assert_eq!(shrunk[0].end, 3.0);
    let grown = clip_edits::resize(&shrunk, 1, true, 1.0, 10.0);
    assert_eq!(grown[1].start, 1.0);
    assert_eq!(clip_edits::resize(&two, 1, false, 99.0, 10.0)[1].end, 10.0);
    assert_eq!(clip_edits::delete(&two, 0), vec![Clip::new(4.0, 10.0, 0)]);
    assert_eq!(clip_edits::delete(&one, 0), one);
    let three = vec![Clip::new(0.0, 2.0, 0), Clip::new(0.0, 2.0, 1), Clip::new(5.0, 6.0, 0)];
    assert_eq!(clip_edits::move_clip(&three, 2, 0)[0], Clip::new(5.0, 6.0, 0));
    assert_eq!(clip_edits::drop_index(&three, 0, 3.5), 2);
    assert_eq!(clip_edits::drop_index(&three, 2, 0.4), 0);
    assert_eq!(clip_edits::starts(&three), vec![0.0, 2.0, 4.0]);
}

#[test]
fn takes_a_second_take_loads_and_zooms_stay_on_their_take() {
    let dir = tmp("takes");
    let folder = dir.join("b.reel");
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(folder.join("screen.mov"), b"").unwrap();
    let p = Project::new(folder.clone(), meta(2880, 1800, 2.0, 4.0, "display", "screen.mov"), CursorTrack::default(), EditDoc::default());
    p.save_meta().unwrap();
    p.save_cursor().unwrap();
    p.save_edit().unwrap();
    let tf = p.next_take_folder();
    assert_eq!(tf.file_name().unwrap(), "take-2");
    std::fs::create_dir_all(&tf).unwrap();
    std::fs::write(tf.join("screen.mp4"), b"").unwrap();
    Take::new(tf.clone(), meta(1920, 1080, 1.0, 6.0, "import", "screen.mp4"), CursorTrack::default()).save().unwrap();
    let p = Project::load(&folder).unwrap();
    assert!(p.takes.len() == 2 && p.duration_of_take(1) == 6.0 && !p.takes[1].has_cursor());
    assert_eq!(p.next_take_folder().file_name().unwrap(), "take-3");
    assert_eq!(take_folders(&folder), vec![tf]);
    let segs = [ZoomSegment::new(0.0, 2.0, 2.0, false, 0), ZoomSegment::new(1.0, 3.0, 2.0, false, 1)];
    let re = segment_edits::re_auto(&segs, &[CursorSample::new(2.0, 0.5, 0.5)], 6.0, 1);
    assert!(re.contains(&segs[0]));
    let old: ZoomSegment = from_json(format!(r#"{{"id":"{}","start":1,"end":2,"scale":2,"auto":true}}"#, new_id()).as_bytes()).unwrap();
    assert_eq!(old.take, 0);
    let planner = Planner::from_project(&p);
    let f2 = planner.frame_rect(1);
    assert!((f2.w / f2.h - 16.0 / 9.0).abs() < 0.01);
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn new_folder_names_like_the_mac() {
    let dir = tmp("names");
    let at = chrono::NaiveDate::from_ymd_opt(2026, 10, 18).unwrap().and_hms_opt(14, 2, 11).unwrap();
    let a = Project::new_folder_local(&dir, at);
    assert_eq!(a.file_name().unwrap(), "2026-10-18 14.02.11.reel");
    std::fs::create_dir_all(&a).unwrap();
    let b = Project::new_folder_local(&dir, at);
    assert_eq!(b.file_name().unwrap(), "2026-10-18 14.02.11 2.reel");
    std::fs::create_dir_all(&b).unwrap();
    assert_eq!(Project::new_folder_local(&dir, at).file_name().unwrap(), "2026-10-18 14.02.11 3.reel");
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn the_music_library_parses_and_tracks_without_a_file_are_skipped() {
    let dir = tmp("music");
    std::fs::write(dir.join("morning.m4a"), b"x").unwrap();
    let json = br#"[{"id": "morning", "title": "Morning", "artist": "Someone", "duration": 154, "genres": ["dreamy"],
      "license": "cc0", "licenseVersion": "1.0", "audioURL": "morning.m4a", "about": "Soft and bright."},
     {"id": "gone", "title": "Gone", "artist": "Someone", "duration": 60, "genres": [], "license": "pdm", "audioURL": "gone.m4a"}]"#;
    let songs = music::parse_library(json, &dir).unwrap();
    assert_eq!(songs.len(), 1);
    let t = &songs[0];
    assert!(t.title == "Morning" && t.duration == 154.0 && t.genres == ["dreamy"]);
    assert!(t.audio_url.starts_with("file://") && t.audio_url.ends_with("morning.m4a"));
    assert!(!t.needs_credit() && t.license_label() == "CC0");
    let mut doc = EditDoc::default();
    doc.music = Some(MusicChoice::new(t.clone(), "music-x.m4a"));
    let back: EditDoc = from_json(to_swift_json(&doc).unwrap().as_bytes()).unwrap();
    assert_eq!(back.music, doc.music);
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn the_apps_own_music_library_is_all_there_and_free_of_conditions() {
    let folder = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../Resources/Music");
    let songs = music::parse_library(&std::fs::read(folder.join("library.json")).unwrap(), &folder).unwrap();
    assert!(songs.len() >= 15, "{}", songs.len());
    assert!(songs.iter().all(|s| !s.needs_credit()));
    assert!(songs.iter().all(|s| s.genres.iter().any(|g| MOODS.iter().any(|m| m.feel == g))));
}

#[test]
fn cursor_look_round_trips() {
    let mut doc = EditDoc::default();
    doc.cursor_style = CursorStyle::Tag;
    doc.cursor_tint = CursorTint::Mint;
    doc.cursor_label = "Connor".into();
    let back: EditDoc = from_json(to_swift_json(&doc).unwrap().as_bytes()).unwrap();
    assert!(back.cursor_style == CursorStyle::Tag && back.cursor_tint == CursorTint::Mint && back.cursor_label == "Connor");
    let old: EditDoc = from_json(b"{}").unwrap();
    assert_eq!(old.cursor_style, CursorStyle::Classic);
}

#[test]
fn camera_clips() {
    let a = CameraClip::new("a.mov", 1.0, 4.0, false);
    let b = CameraClip::new("b.mov", 3.0, 2.0, false);
    let both = camera_mod::insert(b, &[a.clone()]);
    assert!(both.len() == 2 && near(both[0].end(), 3.0, 1e-3) && both[1].file == "b.mov");
    let over = camera_mod::insert(CameraClip::new("c.mov", 0.5, 9.0, false), &both);
    assert!(over.len() == 1 && over[0].file == "c.mov");
    assert!(camera_mod::presence(&a, 0.5) == 0.0 && camera_mod::presence(&a, 3.0) == 1.0);
    assert!(camera_mod::presence(&a, 1.05) > 0.0 && camera_mod::presence(&a, 1.05) < 0.5);
    let quiet = music_envelope::gain(5.0, 20.0, true, true, &[(4.0, 8.0)]);
    let loud = music_envelope::gain(12.0, 20.0, true, true, &[(4.0, 8.0)]);
    assert!(near(quiet, music_envelope::DUCK_LEVEL, 1e-3) && near(loud, 1.0, 1e-3));
    assert_eq!(music_envelope::gain(0.0, 20.0, true, true, &[]), 0.0);
    let mut doc = EditDoc::default();
    doc.camera_clips = vec![a.clone()];
    doc.camera_look.corner = CameraCorner::TopLeft;
    let back: EditDoc = from_json(to_swift_json(&doc).unwrap().as_bytes()).unwrap();
    assert!(back.camera_clips == vec![a] && back.camera_look.corner == CameraCorner::TopLeft);
    let takes = [PlanTake { meta: meta(1920, 1080, 1.0, 10.0, "display", "screen.mov"), cursor: CursorTrack::default(), dir: String::new() }];
    let p = Planner::new(&doc, &takes);
    let bubble = p.bubble_rect();
    // Top-left origin here (the Mac's check is in CoreImage's y-up).
    assert!(bubble.x < p.canvas.width as f64 / 4.0 && bubble.y < p.canvas.height as f64 / 4.0);
}

#[test]
fn hiding_and_cropping_rect_maths_and_edit_json() {
    let r = NormRect::new(0.6, 0.1, 0.3, 0.5);
    assert_eq!(r.moved(0.3, -0.5), NormRect::new(0.7, 0.0, 0.3, 0.5));
    let grown = r.resized(0.0, 1.0, -0.1, 0.2, 0.02);
    assert!(near(grown.x, 0.5, 1e-3) && near(grown.max_x(), 0.9, 1e-3) && near(grown.y, 0.1, 1e-3) && near(grown.max_y(), 0.8, 1e-3));
    let flat = r.resized(1.0, 0.5, -0.5, 0.3, 0.05);
    assert!(near(flat.w, 0.05, 1e-3) && near(flat.h, 0.5, 1e-3));
    let p = r.local(0.75, 0.35);
    assert!(near(p.0, 0.5, 1e-3) && near(p.1, 0.5, 1e-3) && near(r.global(p.0, p.1).0, 0.75, 1e-3));
    let mut b = BlurRegion::new(0, r, BlurStyle::Pixelate, 0.6, Some(2.0), None);
    assert!(!b.covers(1.0) && b.covers(2.0) && b.covers(99.0));
    b.end = Some(5.0);
    assert!(!b.covers(5.0) && b.covers(4.9));
    let mut doc = EditDoc::default();
    doc.blurs = vec![b.clone()];
    doc.set_crop(NormRect::new(0.0, 0.0, 0.5, 1.0), 0);
    let back: EditDoc = from_json(to_swift_json(&doc).unwrap().as_bytes()).unwrap();
    assert!(back.blurs == vec![b] && back.crop(0) == NormRect::new(0.0, 0.0, 0.5, 1.0) && back.crop(1) == NormRect::FULL);
    doc.set_crop(NormRect::FULL, 0);
    assert!(doc.crops.is_empty());
    let old: EditDoc = from_json(br#"{"padding": 0.1}"#).unwrap();
    assert!(old.blurs.is_empty() && old.crops.is_empty());
}

#[test]
fn cropping_to_a_square_makes_the_frame_square() {
    let m = meta(400, 200, 1.0, 10.0, "display", "screen.mov");
    let mut doc = EditDoc::default();
    doc.canvas_aspect = 1.0;
    doc.backdrop = Backdrop::None;
    let takes = [PlanTake { meta: m, cursor: CursorTrack::default(), dir: String::new() }];
    let whole = Planner::new(&doc, &takes).frame_rect(0);
    doc.set_crop(NormRect::new(0.5, 0.0, 0.5, 1.0), 0);
    let square = Planner::new(&doc, &takes);
    let fs = square.frame_rect(0);
    assert!((whole.w / whole.h - 2.0).abs() < 0.02 && (fs.w / fs.h - 1.0).abs() < 0.02);
    // The plan shows only the right half of the source, filling the frame.
    let plan = square.plan_take(0, 0.0);
    assert_eq!((plan.source.bounds.x, plan.source.bounds.w), (200.0, 200.0));
    assert_eq!((plan.source.rect.x, plan.source.rect.w), (200.0, 200.0));
    // Hides land in whole source pixels.
    let hides = monetshot_core::plan::hides(
        &[BlurRegion::new(0, NormRect::new(0.625, 0.0, 0.25, 1.0), BlurStyle::Blur, 1.0, Some(1.0), Some(3.0))],
        2.0,
        400.0,
        200.0,
    );
    assert_eq!((hides[0].rect.x, hides[0].rect.w, hides[0].rect.h), (250.0, 100.0, 200.0));
    assert!(monetshot_core::plan::hides(&[BlurRegion::new(0, NormRect::FULL, BlurStyle::Blur, 1.0, Some(1.0), Some(3.0))], 4.0, 400.0, 200.0).is_empty());
}
