//! A recording on disk: `<name>.reel/` with the first take's files at the
//! top and further takes in `take-2/`, `take-3/`, … The videos are never
//! modified; every edit is re-rendered from these files.

use crate::json::{from_json, to_swift_json, IsoDate};
use crate::model::{Clip, CursorTrack, EditDoc, RecordingMeta};
use crate::timemap::TimeMap;
use std::fmt;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

#[derive(Debug)]
pub enum LoadError {
    /// "recording is missing meta.json"
    Missing(String),
    Damaged(String, serde_json::Error),
}

impl fmt::Display for LoadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            LoadError::Missing(n) => write!(f, "recording is missing {n}"),
            LoadError::Damaged(n, e) => write!(f, "{n} is damaged: {e}"),
        }
    }
}

impl std::error::Error for LoadError {}

/// Writes `value` as the Mac does, atomically (temp file + rename).
pub fn write_json<T: serde::Serialize>(value: &T, path: &Path) -> io::Result<()> {
    let text = to_swift_json(value).map_err(io::Error::other)?;
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let tmp = path.with_file_name(format!(".{name}.tmp-{}", std::process::id()));
    fs::write(&tmp, text.as_bytes())?;
    fs::rename(&tmp, path).inspect_err(|_| {
        let _ = fs::remove_file(&tmp);
    })
}

/// One recorded (or imported) video with its pointer log.
#[derive(Debug, Clone, PartialEq)]
pub struct Take {
    /// The project folder for the first take, `take-N/` after.
    pub folder: PathBuf,
    pub meta: RecordingMeta,
    pub cursor: CursorTrack,
}

impl Take {
    pub fn new(folder: PathBuf, meta: RecordingMeta, cursor: CursorTrack) -> Take {
        Take { folder, meta, cursor }
    }

    pub fn video_path(&self) -> PathBuf {
        self.folder.join(&self.meta.video)
    }
    pub fn camera_path(&self) -> Option<PathBuf> {
        self.meta.camera.as_ref().map(|c| self.folder.join(c))
    }
    /// Imported videos carry no pointer log, so no cursor is drawn on them.
    pub fn has_cursor(&self) -> bool {
        !self.cursor.samples.is_empty()
    }

    pub fn load(folder: &Path) -> Result<Take, LoadError> {
        let meta_bytes = fs::read(folder.join("meta.json")).map_err(|_| LoadError::Missing("meta.json".into()))?;
        let meta: RecordingMeta = from_json(&meta_bytes).map_err(|e| LoadError::Damaged("meta.json".into(), e))?;
        // A missing or damaged cursor log means no cursor, as on the Mac.
        let cursor = fs::read(folder.join("cursor.json")).ok().and_then(|b| from_json(&b).ok()).unwrap_or_default();
        if !folder.join(&meta.video).exists() {
            return Err(LoadError::Missing(meta.video.clone()));
        }
        Ok(Take { folder: folder.to_path_buf(), meta, cursor })
    }

    pub fn save(&self) -> io::Result<()> {
        fs::create_dir_all(&self.folder)?;
        write_json(&self.meta, &self.folder.join("meta.json"))?;
        write_json(&self.cursor, &self.folder.join("cursor.json"))
    }
}

/// A recording folder: its takes and the edit.
#[derive(Debug, Clone, PartialEq)]
pub struct Project {
    pub folder: PathBuf,
    pub takes: Vec<Take>,
    pub edit: EditDoc,
}

impl Project {
    pub fn new(folder: PathBuf, meta: RecordingMeta, cursor: CursorTrack, edit: EditDoc) -> Project {
        Project { takes: vec![Take::new(folder.clone(), meta, cursor)], folder, edit }
    }

    /// A project whose first take is `take` (its folder is the project's).
    pub fn from_take(take: Take, edit: EditDoc) -> Project {
        Project { folder: take.folder.clone(), takes: vec![take], edit }
    }

    /// The first take's meta, which sets the canvas and the name.
    pub fn meta(&self) -> &RecordingMeta {
        &self.takes[0].meta
    }
    pub fn meta_mut(&mut self) -> &mut RecordingMeta {
        &mut self.takes[0].meta
    }
    pub fn cursor(&self) -> &CursorTrack {
        &self.takes[0].cursor
    }
    pub fn cursor_mut(&mut self) -> &mut CursorTrack {
        &mut self.takes[0].cursor
    }
    pub fn video_path(&self) -> PathBuf {
        self.takes[0].video_path()
    }
    /// "2026-11-01 21.56.12"
    pub fn name(&self) -> String {
        self.folder.file_stem().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
    }
    /// The clips in play order.
    pub fn clips(&self) -> Vec<Clip> {
        self.edit.kept_clips(self.meta().duration)
    }
    pub fn time_map(&self) -> TimeMap {
        TimeMap::new(&self.edit, self.meta().duration)
    }
    pub fn duration_of_take(&self, i: i64) -> f64 {
        usize::try_from(i).ok().and_then(|i| self.takes.get(i)).map_or(0.0, |t| t.meta.duration)
    }

    /// Loads a `.reel` folder. A missing or damaged edit.json is a fresh
    /// edit; takes that fail to load are skipped (both as the Mac does).
    pub fn load(folder: &Path) -> Result<Project, LoadError> {
        let first = Take::load(folder)?;
        let edit = fs::read(folder.join("edit.json")).ok().and_then(|b| from_json(&b).ok()).unwrap_or_default();
        let mut p = Project { folder: folder.to_path_buf(), takes: vec![first], edit };
        for dir in take_folders(folder) {
            if let Ok(t) = Take::load(&dir) {
                p.takes.push(t);
            }
        }
        Ok(p)
    }

    /// A fresh folder for the next take.
    pub fn next_take_folder(&self) -> PathBuf {
        let used = take_folders(&self.folder).iter().filter_map(|d| take_number(d)).max().unwrap_or(1);
        self.folder.join(format!("take-{}", used + 1))
    }

    pub fn save_edit(&self) -> io::Result<()> {
        write_json(&self.edit, &self.folder.join("edit.json"))
    }
    pub fn save_meta(&self) -> io::Result<()> {
        write_json(self.meta(), &self.folder.join("meta.json"))
    }
    pub fn save_cursor(&self) -> io::Result<()> {
        write_json(self.cursor(), &self.folder.join("cursor.json"))
    }

    /// A fresh, unique folder like "2026-10-18 14.02.11.reel" (then
    /// "… 2.reel", "… 3.reel"). `now` is local wall-clock time.
    pub fn new_folder(dir: &Path, now: IsoDate) -> PathBuf {
        use chrono::TimeZone;
        let local = chrono::Local
            .timestamp_opt(now.0, 0)
            .single()
            .map(|d| d.naive_local())
            .unwrap_or_else(|| chrono::DateTime::from_timestamp(now.0, 0).unwrap_or_default().naive_utc());
        Project::new_folder_local(dir, local)
    }

    /// `new_folder` for a given local wall-clock time.
    pub fn new_folder_local(dir: &Path, now: chrono::NaiveDateTime) -> PathBuf {
        let stamp = now.format("%Y-%m-%d %H.%M.%S").to_string();
        let mut url = dir.join(format!("{stamp}.reel"));
        let mut n = 2;
        while url.exists() {
            url = dir.join(format!("{stamp} {n}.reel"));
            n += 1;
        }
        url
    }

    /// `new_folder` at the current local time.
    pub fn new_folder_now(dir: &Path) -> PathBuf {
        Project::new_folder_local(dir, chrono::Local::now().naive_local())
    }
}

fn take_number(dir: &Path) -> Option<i64> {
    dir.file_name()?.to_str()?.strip_prefix("take-")?.parse().ok()
}

/// `take-2`, `take-3`, … in number order.
pub fn take_folders(folder: &Path) -> Vec<PathBuf> {
    let Ok(rd) = fs::read_dir(folder) else { return vec![] };
    let mut v: Vec<(i64, PathBuf)> = rd
        .filter_map(|e| e.ok())
        .filter_map(|e| {
            let p = e.path();
            take_number(&p).map(|k| (k, p))
        })
        .collect();
    v.sort_by_key(|x| x.0);
    v.into_iter().map(|x| x.1).collect()
}

/// Recordings in a library folder, newest first by name.
pub fn list_recordings(dir: &Path) -> Vec<PathBuf> {
    let Ok(rd) = fs::read_dir(dir) else { return vec![] };
    let mut v: Vec<PathBuf> = rd
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "reel") && p.is_dir())
        .collect();
    v.sort();
    v.reverse();
    v
}

/// `IsoDate` for a meta written now.
pub fn now() -> IsoDate {
    IsoDate::now()
}
