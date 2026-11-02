//! Home's data: the recordings as cards (HomeModel on the Mac).

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::SystemTime;

use monetshot_core::{paths, project, Project, TimeMap};
use serde::Serialize;

use crate::{library, log};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub path: PathBuf,
    pub title: String,
    pub duration: f64,
    pub clips: usize,
    pub takes: usize,
}

/// Every recording that loads, newest first.
pub fn items() -> Vec<Item> {
    project::list_recordings(&paths::library_dir())
        .into_iter()
        .filter_map(|url| {
            let p = Project::load(&url).ok()?;
            let clips = p.clips();
            Some(Item {
                title: library::title(&url),
                duration: TimeMap::from_clips(&clips).duration(),
                clips: clips.len(),
                takes: p.takes.len(),
                path: url,
            })
        })
        .collect()
}

fn modified(p: &Path) -> Option<SystemTime> {
    std::fs::metadata(p).and_then(|m| m.modified()).ok()
}

/// A small picture of the recording for its card, with its backdrop: the
/// shared `thumb.jpg` (the Mac writes the same one), redrawn when the edit
/// is newer. If the render fails, a frame of the raw video from our own
/// cache stands in (never written into the recording).
pub fn thumb(reel: &Path) -> Option<PathBuf> {
    if monetshot_export::thumb_is_fresh(reel) {
        return Some(reel.join("thumb.jpg"));
    }
    let p = Project::load(reel).ok()?;
    match monetshot_export::write_thumb(&p) {
        Ok(path) => Some(path),
        Err(e) => {
            log::error(&format!("thumb {}: {e}", reel.display()));
            raw_frame(reel, &p)
        }
    }
}

fn raw_frame(reel: &Path, p: &Project) -> Option<PathBuf> {
    let edit = modified(&reel.join("edit.json")).unwrap_or(SystemTime::UNIX_EPOCH);
    let clips = p.clips();
    let map = TimeMap::from_clips(&clips);
    let at = map.locate((map.duration() / 3.0).min(1.5));
    let take = p.takes.get(usize::try_from(at.take).ok()?)?;
    let cache = paths::support_dir().join("thumbs");
    let _ = std::fs::create_dir_all(&cache);
    let out = cache.join(format!("{:016x}.jpg", hash(&reel.to_string_lossy())));
    let video = take.video_path();
    if modified(&out).is_some_and(|t| t >= edit && modified(&video).is_none_or(|v| t >= v)) {
        return Some(out);
    }
    let ff = monetshot_capture::ffmpeg().ok()?;
    let ok = Command::new(&ff.ffmpeg)
        .args(["-v", "error", "-y", "-ss", &format!("{:.3}", at.time), "-i"])
        .arg(&video)
        .args(["-frames:v", "1", "-vf", "scale=640:-2", "-q:v", "4"])
        .arg(&out)
        .status()
        .is_ok_and(|s| s.success());
    ok.then_some(out)
}

/// FNV-1a: a stable file name for a path.
fn hash(s: &str) -> u64 {
    s.bytes().fold(0xcbf29ce484222325, |h, b| (h ^ b as u64).wrapping_mul(0x100000001b3))
}

/// To the Trash / Recycle Bin (so it can be put back), never deleted outright.
pub fn trash(reel: &Path) -> Result<(), String> {
    trash::delete(reel).map_err(|e| e.to_string())
}

/// Any video as a new Monet Shot edit (Imports.newProject(fromVideo:)).
pub fn import(video: &Path) -> Result<PathBuf, String> {
    let folder = monetshot_export::imports::new_project_from_video(video, &paths::library_dir()).map_err(|e| e.to_string())?;
    log::info(&format!("imported {} as {}", video.display(), folder.display()));
    Ok(folder)
}
