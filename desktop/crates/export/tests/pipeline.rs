//! The ffmpeg pipeline end to end on generated media: import a video as a
//! recording, add a take, export with music and a camera clip, and check
//! what comes out. Skipped when ffmpeg isn't installed.

use monetshot_core::{CameraClip, MusicChoice, Project, Song};
use monetshot_export::{export, ffmpeg, imports, probe, render_still, thumb_is_fresh, write_thumb};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::AtomicBool;

fn tmp(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("monetshot-export-test-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn make(args: &[&str], out: &Path) {
    let t = ffmpeg::tools().unwrap();
    let ok = Command::new(&t.ffmpeg).args(["-v", "error", "-nostdin", "-y"]).args(args).arg(out).status().unwrap().success();
    assert!(ok, "ffmpeg made {}", out.display());
}

#[test]
fn import_add_take_export() {
    if ffmpeg::tools().is_err() {
        eprintln!("no ffmpeg; skipped");
        return;
    }
    let dir = tmp("pipeline");
    let lib = dir.join("library");
    std::fs::create_dir_all(&lib).unwrap();
    let a = dir.join("a.mp4");
    let b = dir.join("b.mov");
    let cam = dir.join("cam.mp4");
    let song = dir.join("song.m4a");
    make(&["-f", "lavfi", "-i", "testsrc2=s=640x400:r=30:d=3", "-pix_fmt", "yuv420p"], &a);
    make(&["-f", "lavfi", "-i", "smptebars=s=320x240:r=25:d=2", "-pix_fmt", "yuv420p"], &b);
    make(&["-f", "lavfi", "-i", "color=c=orange:s=320x240:r=30:d=1.5", "-f", "lavfi", "-i", "sine=f=440:d=1.5", "-shortest", "-pix_fmt", "yuv420p"], &cam);
    make(&["-f", "lavfi", "-i", "sine=f=220:d=10", "-c:a", "aac"], &song);

    let reel = imports::new_project_from_video(&a, &lib).unwrap();
    assert!(reel.extension().unwrap() == "reel");
    let mut p = Project::load(&reel).unwrap();
    assert_eq!((p.meta().pixel_width, p.meta().pixel_height, p.meta().source.as_str()), (640, 400, "import"));
    assert!((p.meta().duration - 3.0).abs() < 0.1);
    assert_eq!(p.meta().video, "screen.mp4");

    let k = imports::video(&b, &mut p).unwrap();
    assert_eq!(k, 1);
    assert!(reel.join("take-2/screen.mov").exists());
    let mut clips = p.clips();
    clips.push(monetshot_core::Clip::new(0.5, 1.5, 1));
    p.edit.clips = Some(clips);
    std::fs::copy(&cam, reel.join("camera-1.mp4")).unwrap();
    p.edit.camera_clips = vec![CameraClip::new("camera-1.mp4", 0.5, 1.5, false)];
    std::fs::copy(&song, reel.join("music-x.m4a")).unwrap();
    let track: Song = serde_json::from_str(
        r#"{"id":"x","title":"Tone","artist":"Test","duration":10,"genres":[],"license":"by","licenseVersion":"4.0","audioURL":"x"}"#,
    )
    .unwrap();
    p.edit.music = Some(MusicChoice::new(track, "music-x.m4a"));
    p.edit.output_width = 640;
    p.save_edit().unwrap();
    let p = Project::load(&reel).unwrap();
    assert_eq!(p.takes.len(), 2);

    let out = dir.join("out.mp4");
    let progress = std::sync::Mutex::new(vec![]);
    export(&p, &out, &|f| progress.lock().unwrap().push(f), &AtomicBool::new(false)).unwrap();
    let pr = probe(&out).unwrap();
    assert_eq!((pr.width, pr.height), (640, 360));
    assert!((pr.duration - 4.0).abs() < 0.1, "duration {}", pr.duration);
    assert!(pr.has_audio);
    let prog = progress.lock().unwrap();
    assert!(prog.windows(2).all(|w| w[1] >= w[0]) && *prog.last().unwrap() == 1.0);
    // CC BY music: a credit beside the video.
    assert!(std::fs::read_to_string(dir.join("out.credits.txt")).unwrap().contains("\"Tone\" by Test, CC BY 4.0"));

    // The camera bubble is there mid-clip: an orange pixel at the bubble's centre.
    let still = render_still(&p, 1.2, None).unwrap();
    let planner = monetshot_core::Planner::from_project(&p);
    let r = planner.bubble_rect();
    let (x, y) = ((r.x + r.w / 2.0) as u32, (r.y + r.h / 2.0) as u32);
    let i = ((y * still.width + x) * 4) as usize;
    let px = &still.data[i..i + 3];
    assert!(px[0] > 200 && px[1] > 120 && px[1] < 200 && px[2] < 60, "bubble centre {px:?}");

    // Cancelling leaves nothing behind.
    let cancelled = dir.join("cancelled.mp4");
    let err = export(&p, &cancelled, &|_| {}, &AtomicBool::new(true)).unwrap_err();
    assert!(matches!(err, ffmpeg::ExportError::Cancelled));
    assert!(!cancelled.exists() && !dir.join("cancelled.partial.mp4").exists());

    // Thumbnails: written as the Mac does, fresh until the edit changes.
    assert!(!thumb_is_fresh(&reel));
    write_thumb(&p).unwrap();
    assert!(thumb_is_fresh(&reel));
    let th = image::open(reel.join("thumb.jpg")).unwrap();
    assert_eq!((th.width(), th.height()), (640, 360));

    // Bringing in another recording: its takes, clips and zooms come along.
    let mut q = Project::load(&imports::new_project_from_video(&b, &lib).unwrap()).unwrap();
    let before = q.clips().len();
    let added = imports::recording(&p, &mut q).unwrap();
    assert_eq!(added, vec![1, 2]);
    assert_eq!(q.clips().len(), before + p.clips().len());

    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn music_waveform_and_grid() {
    if ffmpeg::tools().is_err() {
        return;
    }
    let lib = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../Resources/Music");
    let song = lib.join("holiznacc0_night-driving.m4a");
    if !song.exists() {
        return;
    }
    let w = monetshot_export::sound::waveform(&song, 240).unwrap();
    assert_eq!(w.len(), 240);
    assert!(w.iter().cloned().fold(0.0, f32::max) == 1.0);
    let g = monetshot_export::sound::grid(&song).unwrap().expect("a beat");
    assert!(g.bpm() > 60.0 && g.bpm() < 200.0, "{}", g.bpm());
}
