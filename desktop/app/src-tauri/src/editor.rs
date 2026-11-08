//! What an editor page loads and saves. The page keeps the edit as JSON and
//! asks core-wasm for every decision; Rust reads and writes the files, with
//! core's writer, so edit.json stays byte-compatible with the Mac.

use std::path::{Path, PathBuf};

use monetshot_core::{project, EditDoc, Project};
use serde::Serialize;
use serde_json::Value;

use crate::library;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TakeData {
    /// meta.json and cursor.json, as core-wasm takes them.
    pub meta: Value,
    pub cursor: Value,
    /// The take's folder relative to the recording ("" for the first).
    pub dir: String,
    /// Absolute paths for the page to load (asset protocol).
    pub video: PathBuf,
    pub camera: Option<PathBuf>,
    /// The file with your voice (absolute), and transcript.json if heard.
    pub voice: Option<PathBuf>,
    pub transcript: Option<monetshot_core::Transcript>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorData {
    pub folder: PathBuf,
    pub name: String,
    pub title: String,
    pub edit: Value,
    pub takes: Vec<TakeData>,
}

pub fn load(folder: &Path) -> Result<EditorData, String> {
    let p = Project::load(folder).map_err(|e| e.to_string())?;
    let takes = p
        .takes
        .iter()
        .map(|t| {
            Ok(TakeData {
                meta: serde_json::to_value(&t.meta).map_err(|e| e.to_string())?,
                cursor: serde_json::to_value(&t.cursor).map_err(|e| e.to_string())?,
                dir: t.folder.strip_prefix(&p.folder).map(|d| d.to_string_lossy().to_string()).unwrap_or_default(),
                video: t.video_path(),
                camera: t.camera_path(),
                voice: t.meta.voice.as_ref().map(|v| t.folder.join(v)).filter(|p| p.is_file()),
                transcript: monetshot_core::Transcript::load(&t.folder),
            })
        })
        .collect::<Result<Vec<_>, String>>()?;
    Ok(EditorData {
        name: p.name(),
        title: library::title(&p.folder),
        edit: serde_json::to_value(&p.edit).map_err(|e| e.to_string())?,
        folder: p.folder,
        takes,
    })
}

/// Writes edit.json (sorted keys, the Mac's format; unknown keys kept).
pub fn save(folder: &Path, edit: Value) -> Result<(), String> {
    let doc: EditDoc = serde_json::from_value(edit).map_err(|e| e.to_string())?;
    project::write_json(&doc, &folder.join("edit.json")).map_err(|e| e.to_string())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Filmstrip {
    /// A JPEG grid of `count` tiles, `cols` across, each `tile_w`×`tile_h`.
    pub path: PathBuf,
    pub count: u32,
    pub cols: u32,
    pub tile_w: u32,
    pub tile_h: u32,
    /// Seconds between tiles; tile i shows (i + 0.5) * step.
    pub step: f64,
}

/// Filmstrip frames for a take, every 0.5 s (at most 400), as one image
/// cached by the video's path and age (EditorModel.makeThumbnails).
pub fn filmstrip(video: &Path, duration: f64) -> Result<Filmstrip, String> {
    const STEP: f64 = 0.5;
    const COLS: u32 = 20;
    let (tile_w, tile_h) = (160, 100);
    let count = ((duration / STEP).ceil() as u32).clamp(1, 400);
    let step = if duration / STEP > 400.0 { duration / 400.0 } else { STEP };
    let rows = count.div_ceil(COLS);
    let stamp = std::fs::metadata(video).and_then(|m| m.modified()).ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_secs());
    let key = format!("{}@{stamp}", video.display());
    let hash = key.bytes().fold(0xcbf29ce484222325u64, |h, b| (h ^ b as u64).wrapping_mul(0x100000001b3));
    let dir = monetshot_core::paths::support_dir().join("filmstrips");
    let _ = std::fs::create_dir_all(&dir);
    let out = dir.join(format!("{hash:016x}.jpg"));
    let strip = Filmstrip { path: out.clone(), count, cols: COLS, tile_w, tile_h, step };
    if out.exists() {
        return Ok(strip);
    }
    let ff = monetshot_capture::ffmpeg().map_err(|e| e.to_string())?;
    let vf = format!(
        "fps=1/{step},scale={tile_w}:{tile_h}:force_original_aspect_ratio=increase,crop={tile_w}:{tile_h},tile={COLS}x{rows}"
    );
    let tmp = out.with_extension("part.jpg");
    let ok = std::process::Command::new(&ff.ffmpeg)
        .args(["-v", "error", "-y", "-ss", &format!("{:.3}", step / 2.0), "-i"])
        .arg(video)
        .args(["-vf", &vf, "-frames:v", "1", "-q:v", "5"])
        .arg(&tmp)
        .status()
        .is_ok_and(|s| s.success());
    if !ok {
        return Err(format!("filmstrip: ffmpeg failed on {}", video.display()));
    }
    std::fs::rename(&tmp, &out).map_err(|e| e.to_string())?;
    Ok(strip)
}

#[derive(Serialize, serde::Deserialize, Clone)]
pub struct Painting {
    pub file: String,
    pub title: String,
    pub artist: String,
    #[serde(default)]
    pub licence: String,
    #[serde(default)]
    pub source: String,
    /// Absolute paths, filled in here.
    #[serde(default)]
    pub path: PathBuf,
    #[serde(default)]
    pub thumb: PathBuf,
}

/// The paintings that come with Monet Shot (BackdropGallery): the bundled
/// Backdrops folder, or the repo's in a development run.
pub fn gallery(resources: Option<PathBuf>) -> Vec<Painting> {
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../Resources/Backdrops");
    let Some(folder) = [resources.map(|r| r.join("Backdrops")), Some(repo)]
        .into_iter()
        .flatten()
        .find(|f| f.join("credits.json").exists())
    else {
        crate::log::error("backdrop gallery: none found");
        return vec![];
    };
    let list: Vec<Painting> = std::fs::read(folder.join("credits.json"))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default();
    list.into_iter()
        .map(|mut p| {
            p.path = folder.join(&p.file);
            p.thumb = folder.join("thumbs").join(&p.file);
            // A bundle without the thumbs folder still shows the painting.
            if !p.thumb.exists() {
                p.thumb = p.path.clone();
            }
            p
        })
        .collect()
}

/// A name inside the recording: no folders, no way out of it.
fn inside(folder: &Path, name: &str) -> Result<PathBuf, String> {
    let ok = !name.is_empty() && Path::new(name).file_name().is_some_and(|f| f == name) && !name.starts_with('.');
    ok.then(|| folder.join(name)).ok_or_else(|| format!("bad file name {name}"))
}

/// Copies a picture into the recording (so it travels with it) and returns
/// the name it was given. Gallery paintings keep "backdrop-<file>", so the
/// gallery can tell which one is in use.
pub fn backdrop_copy(folder: &Path, from: &Path, name: Option<String>) -> Result<String, String> {
    let ext = from.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_else(|| "img".into());
    let name = name.unwrap_or_else(|| format!("backdrop-{}.{ext}", crate::bar::now_ms() / 1000));
    let dest = inside(folder, &name)?;
    let _ = std::fs::remove_file(&dest);
    std::fs::copy(from, &dest).map_err(|e| e.to_string())?;
    Ok(name)
}

/// Removes a file the edit no longer uses (an old backdrop, old music).
pub fn remove_file(folder: &Path, name: &str) -> Result<(), String> {
    std::fs::remove_file(inside(folder, name)?).map_err(|e| e.to_string())
}
