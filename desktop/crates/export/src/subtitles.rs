//! Your voice in the export (each take's `voice` file, following its clips
//! as `Render/Voice.swift` lays it on the Mac) and the subtitles written
//! beside it.

use crate::export::Placed;
use crate::ffmpeg::probe;
use monetshot_core::captions::{self, Transcript};
use monetshot_core::plan::Planner;
use monetshot_core::text::TextAnimation;
use monetshot_core::timemap::TimeMap;
use monetshot_core::Project;
use std::path::{Path, PathBuf};

/// The voice pieces: each take's voice file (when it isn't the camera file,
/// whose sound the camera already brings) under the clips that show that take.
pub(crate) fn voice_audio(project: &Project, map: &TimeMap) -> Vec<Placed> {
    let mut out = vec![];
    for s in &map.spans {
        let Some(take) = usize::try_from(s.take).ok().and_then(|i| project.takes.get(i)) else { continue };
        let Some(name) = &take.meta.voice else { continue };
        if take.meta.camera.as_ref() == Some(name) {
            continue;
        }
        let file = take.folder.join(name);
        let Ok(p) = probe(&file) else { continue };
        let off = take.meta.voice_offset.unwrap_or(0.0);
        let from = (s.start - off).max(0.0);
        let to = p.duration.min(s.end - off);
        if to - from > 0.05 && p.has_audio {
            out.push(Placed { file, from, duration: (to - from) / s.speed, at: s.at + (from - (s.start - off)) / s.speed, speed: s.speed });
        }
    }
    out
}

/// Every take's transcript, in take order.
pub fn transcripts(project: &Project) -> Vec<Option<Transcript>> {
    project.takes.iter().map(|t| Transcript::load(&t.folder)).collect()
}

/// The subtitles for the edit (whether or not the captions show): SubRip
/// text, None when nothing was transcribed.
pub fn srt(project: &Project) -> Option<String> {
    let planner = Planner::from_project(project);
    let anim = TextAnimation::Words;
    let overlays = captions::overlays(&transcripts(project), &planner.map, planner.canvas.width as f64, planner.canvas.height as f64, anim);
    (!overlays.is_empty()).then(|| captions::srt(&overlays))
}

/// Writes `<video>.srt` beside an export (or removes a stale one).
pub fn write_srt(project: &Project, video: &Path) -> std::io::Result<Option<PathBuf>> {
    let path = video.with_extension("srt");
    match srt(project) {
        Some(text) => {
            std::fs::write(&path, text)?;
            Ok(Some(path))
        }
        None => {
            let _ = std::fs::remove_file(&path);
            Ok(None)
        }
    }
}

/// Plain text of everything said, in play order ("Copy transcript").
pub fn transcript_text(project: &Project) -> String {
    captions::text(&captions::words(&transcripts(project), &project.time_map()))
}
