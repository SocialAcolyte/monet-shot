//! Bringing footage in: any video file as a new recording or a new take, or
//! the takes of another recording. Files are copied in, as on the Mac
//! (`Model/Imports.swift`).

use crate::ffmpeg::{probe, ExportError};
use monetshot_core::project::Take;
use monetshot_core::{new_id, Clip, CursorTrack, EditDoc, IsoDate, Project, RecordingMeta, TakeCrop};
use std::path::{Path, PathBuf};

fn video_name(src: &Path) -> String {
    let ext = src.extension().map(|e| e.to_string_lossy().to_lowercase()).filter(|e| !e.is_empty()).unwrap_or_else(|| "mov".into());
    format!("screen.{ext}")
}

fn imported_meta(src: &Path, name: &str) -> Result<RecordingMeta, ExportError> {
    let p = probe(src)?;
    if !p.has_video || p.width == 0 {
        return Err(ExportError::NoVideo(src.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()));
    }
    // Assume a Retina capture; this only sizes the cursor, which an import doesn't draw.
    Ok(RecordingMeta::new(p.width as i64, p.height as i64, 2.0, p.duration, IsoDate::now(), "import", name))
}

/// A new recording made from a video file, so any screen recording can be
/// edited. Returns its folder (in `library`).
pub fn new_project_from_video(video: &Path, library: &Path) -> Result<PathBuf, ExportError> {
    let name = video_name(video);
    let meta = imported_meta(video, &name)?;
    let folder = Project::new_folder(library, IsoDate::now());
    std::fs::create_dir_all(&folder)?;
    let done = (|| -> Result<(), ExportError> {
        std::fs::copy(video, folder.join(&name))?;
        let p = Project::new(folder.clone(), meta, CursorTrack::default(), EditDoc::default());
        p.save_meta()?;
        p.save_cursor()?;
        p.save_edit()?;
        Ok(())
    })();
    if let Err(e) = done {
        let _ = std::fs::remove_dir_all(&folder);
        return Err(e);
    }
    Ok(folder)
}

/// Copies a video file in as a new take (no pointer log, so no cursor is
/// drawn on it). Returns the new take's index.
pub fn video(video: &Path, project: &mut Project) -> Result<i64, ExportError> {
    let name = video_name(video);
    let meta = imported_meta(video, &name)?;
    let folder = project.next_take_folder();
    std::fs::create_dir_all(&folder)?;
    std::fs::copy(video, folder.join(&name))?;
    let take = Take::new(folder, meta, CursorTrack::default());
    take.save()?;
    project.takes.push(take);
    Ok(project.takes.len() as i64 - 1)
}

/// Copies every take of `other` in, with its clips (appended to the end),
/// zooms, hides and crops. Returns the new takes' indices. The caller saves
/// the edit.
pub fn recording(other: &Project, project: &mut Project) -> Result<Vec<i64>, ExportError> {
    let mut map: Vec<(i64, i64)> = vec![];
    for (i, t) in other.takes.iter().enumerate() {
        let folder = project.next_take_folder();
        std::fs::create_dir_all(&folder)?;
        std::fs::copy(t.video_path(), folder.join(&t.meta.video))?;
        let take = Take::new(folder, t.meta.clone(), t.cursor.clone());
        take.save()?;
        project.takes.push(take);
        map.push((i as i64, project.takes.len() as i64 - 1));
    }
    let to = |k: i64| map.iter().find(|m| m.0 == k).map(|m| m.1);
    let mut clips = project.clips();
    clips.extend(other.clips().into_iter().filter_map(|c| to(c.take).map(|t| Clip::new(c.start, c.end, t))));
    let e = &mut project.edit;
    e.clips = Some(clips);
    e.cuts = vec![];
    e.trim_start = 0.0;
    e.trim_end = None;
    e.segments.extend(other.edit.segments.iter().filter_map(|s| {
        to(s.take).map(|t| {
            let mut z = s.clone();
            z.id = new_id();
            z.take = t;
            z
        })
    }));
    e.blurs.extend(other.edit.blurs.iter().filter_map(|b| {
        to(b.take).map(|t| {
            let mut z = b.clone();
            z.id = new_id();
            z.take = t;
            z
        })
    }));
    e.crops.extend(other.edit.crops.iter().filter_map(|c| to(c.take).map(|t| TakeCrop::new(t, c.rect))));
    Ok(map.into_iter().map(|m| m.1).collect())
}
