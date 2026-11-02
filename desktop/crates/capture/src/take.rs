//! Writing a finished recording as the Mac's `ScreenRecorder.finish()` does:
//! meta.json + cursor.json (+ edit.json with the pause cuts, auto-zooms and
//! the stop trim for a new recording). All JSON goes through monetshot-core.

use std::path::{Path, PathBuf};

use monetshot_core as core;

use crate::pointer::{last_time_off_bars, Bar, Sample};
use crate::session::Video;
use crate::{CaptureError, Event, SourceKind, StartOptions};

/// The folder to record into, and the project when it's a new take.
pub(crate) fn folder_for(opts: &StartOptions) -> Result<(PathBuf, Option<PathBuf>), CaptureError> {
    if let Some(project) = &opts.take_into {
        let p = core::Project::load(project).map_err(|e| CaptureError::Other(format!("could not open {}: {e}", project.display())))?;
        return Ok((p.next_take_folder(), Some(project.clone())));
    }
    std::fs::create_dir_all(&opts.library)?;
    Ok((core::Project::new_folder(&opts.library, core::IsoDate::now()), None))
}

pub(crate) struct TakeInput<'a> {
    pub folder: &'a Path,
    pub take_into: Option<&'a Path>,
    pub video: &'a Video,
    pub duration: f64,
    pub kind: SourceKind,
    pub scale: f64,
    pub samples: Vec<Sample>,
    pub clicks: Vec<Sample>,
    pub pauses: Vec<(f64, f64)>,
    pub open_pause: Option<f64>,
    pub bars: Vec<Bar>,
    /// camera.mp4 and the take time it starts at.
    pub camera: Option<(PathBuf, f64)>,
}

pub(crate) fn write(i: TakeInput) -> Result<Event, CaptureError> {
    let video_name = i.video.file.file_name().and_then(|n| n.to_str()).unwrap_or("screen.mp4");
    let mut meta = core::RecordingMeta::new(
        i.video.width as i64,
        i.video.height as i64,
        i.scale,
        i.duration,
        core::IsoDate::now(),
        i.kind.meta(),
        video_name,
    );
    if let Some((file, offset)) = &i.camera {
        meta.camera = file.file_name().and_then(|n| n.to_str()).map(String::from);
        meta.camera_offset = *offset;
        log::info!("camera saved with the take, {offset:.2}s offset");
    }
    let to_core = |s: &Sample| core::CursorSample::new(s.t, s.x, s.y);
    let track = core::CursorTrack { samples: i.samples.iter().map(to_core).collect(), clicks: i.clicks.iter().map(to_core).collect(), ..Default::default() };

    let mut edit = core::EditDoc {
        cuts: cuts(&i.pauses, i.open_pause, meta.duration).into_iter().map(|(a, b)| core::Cut::new(a, b)).collect(),
        ..Default::default()
    };
    let map = core::TimeMap::new(&edit, meta.duration);
    let kept: Vec<core::CursorSample> = track.clicks.iter().filter(|c| map.keeps(0, c.t)).cloned().collect();
    edit.segments = core::camera_math::auto_zooms(&kept, meta.duration);
    // The hand travels to the bar to stop: end the edit just before it got there.
    if i.kind == SourceKind::Display && !i.bars.is_empty() {
        if let Some(last) = last_time_off_bars(&i.samples, meta.duration, &i.bars) {
            if meta.duration - last < 6.0 && last > 1.0 {
                edit.trim_end = Some(last);
            }
        }
    }

    let take = core::Take::new(i.folder.to_path_buf(), meta, track);
    if let Some(project) = i.take_into {
        take.save().map_err(|e| CaptureError::Other(e.to_string()))?;
        log::info!("take saved: {} {:.1}s", i.folder.display(), take.meta.duration);
        let clips = edit.kept_clips(take.meta.duration);
        return Ok(Event::FinishedTake { project: project.to_path_buf(), take: i.folder.to_path_buf(), clips });
    }
    let project = core::Project::from_take(take, edit);
    project.save_meta().and_then(|_| project.save_cursor()).and_then(|_| project.save_edit()).map_err(|e| CaptureError::Other(e.to_string()))?;
    log::info!(
        "recording saved: {} {:.1}s, {} samples, {} clicks",
        i.folder.display(),
        project.meta().duration,
        project.cursor().samples.len(),
        project.cursor().clicks.len()
    );
    Ok(Event::Finished { folder: i.folder.to_path_buf() })
}

/// The pauses as cuts: each longer than 0.05 s (already filtered when
/// closed), one still open at the stop running to the end.
fn cuts(pauses: &[(f64, f64)], open: Option<f64>, duration: f64) -> Vec<(f64, f64)> {
    let mut c: Vec<(f64, f64)> = pauses.to_vec();
    if let Some(p) = open {
        c.push((p, duration));
    }
    c.retain(|(a, b)| b > a);
    c.sort_by(|a, b| a.0.total_cmp(&b.0));
    c
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_pause_runs_to_the_end() {
        assert_eq!(cuts(&[(5.0, 6.0), (1.0, 2.0)], Some(9.0), 10.0), vec![(1.0, 2.0), (5.0, 6.0), (9.0, 10.0)]);
        assert_eq!(cuts(&[], Some(12.0), 10.0), vec![]);
    }
}
