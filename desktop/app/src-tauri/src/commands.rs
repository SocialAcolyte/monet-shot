//! Tauri commands: what the pages may ask of the app. Each one is listed in
//! docs/porting/contracts/ipc.md.

use tauri::{AppHandle, Manager};

use crate::bar::{Bar, BarState};
use std::path::PathBuf;

use crate::{camera, editor, home, recorder, windows};

#[tauri::command]
pub fn bar_state(app: AppHandle) -> BarState {
    app.state::<Bar>().snapshot()
}

// Commands that may build a window (the pill, picker, bubble, Home, an
// editor) are async. A sync command runs on the main thread inside
// WebView2's IPC callback, and building a WebView2 window there deadlocks
// on Windows: the window comes up blank and the app hangs.
// run_on_main_thread doesn't help: on the main thread it runs the task
// right away (tauri-runtime-wry's send_user_message).

/// A click on the ring: idle records, a countdown cancels.
#[tauri::command]
pub async fn bar_tap(app: AppHandle) {
    app.state::<Bar>().tap(&app)
}

#[tauri::command]
pub async fn bar_cancel(app: AppHandle) {
    app.state::<Bar>().cancel(&app)
}

#[tauri::command]
pub async fn bar_toggle_pause(app: AppHandle) {
    app.state::<Bar>().toggle_pause(&app)
}

/// The hold ring completed (the pill times the hold itself).
#[tauri::command]
pub async fn bar_stop(app: AppHandle) {
    app.state::<Bar>().stop(&app)
}

#[tauri::command]
pub async fn show_home(app: AppHandle) {
    windows::show_home(&app)
}

/// Displays and windows for our picker, with thumbnails.
#[tauri::command]
pub async fn picker_sources() -> Result<Vec<recorder::SourceView>, String> {
    tauri::async_runtime::spawn_blocking(recorder::sources).await.map_err(|e| e.to_string())?
}

/// The picker's answer: a source id, or null for "never mind".
#[tauri::command]
pub async fn picker_choose(app: AppHandle, id: Option<String>) {
    recorder::choose(&app, id)
}

/// Subscribes this page to the camera's preview frames (raw JPEG bytes).
#[tauri::command]
pub fn camera_preview(channel: tauri::ipc::Channel<tauri::ipc::InvokeResponseBody>) {
    camera::watch(channel)
}

// MARK: Home

#[tauri::command]
pub async fn home_items() -> Vec<home::Item> {
    tauri::async_runtime::spawn_blocking(home::items).await.unwrap_or_default()
}

/// A file path for the card's picture (show it through the asset protocol).
#[tauri::command]
pub async fn home_thumb(path: PathBuf) -> Option<PathBuf> {
    tauri::async_runtime::spawn_blocking(move || home::thumb(&path)).await.ok().flatten()
}

#[tauri::command]
pub async fn open_recording(app: AppHandle, path: PathBuf) {
    windows::open_editor(&app, &path)
}

/// Shows the file in Finder / Explorer / the file manager.
#[tauri::command]
pub fn reveal(app: AppHandle, path: PathBuf) -> Result<(), String> {
    use tauri_plugin_opener::OpenerExt;
    app.opener().reveal_item_in_dir(&path).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn trash(app: AppHandle, path: PathBuf) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || home::trash(&path)).await.map_err(|e| e.to_string())??;
    library_changed(&app);
    Ok(())
}

/// Turns any video into a Monet Shot edit and opens it.
#[tauri::command]
pub async fn import_video(app: AppHandle, path: PathBuf) -> Result<PathBuf, String> {
    let folder = tauri::async_runtime::spawn_blocking(move || home::import(&path)).await.map_err(|e| e.to_string())??;
    library_changed(&app);
    windows::open_editor(&app, &folder);
    Ok(folder)
}

/// Home and the tray's Recent list follow the library.
pub fn library_changed(app: &AppHandle) {
    use tauri::Emitter;
    crate::tray::refresh_menu(app);
    let _ = app.emit("library-changed", ());
}

// MARK: Editor

#[tauri::command]
pub async fn editor_load(path: PathBuf) -> Result<editor::EditorData, String> {
    tauri::async_runtime::spawn_blocking(move || editor::load(&path)).await.map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn editor_save(path: PathBuf, edit: serde_json::Value) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || editor::save(&path, edit)).await.map_err(|e| e.to_string())?
}

/// "Record a new take" from an editor: the editor steps aside, the take
/// lands at the end of this recording.
#[tauri::command]
pub async fn record_take(app: AppHandle, path: PathBuf) {
    app.state::<Bar>().record_take(&app, path)
}

#[tauri::command]
pub async fn filmstrip(video: PathBuf, duration: f64) -> Result<editor::Filmstrip, String> {
    tauri::async_runtime::spawn_blocking(move || editor::filmstrip(&video, duration)).await.map_err(|e| e.to_string())?
}

#[tauri::command]
pub fn backdrop_gallery(app: AppHandle) -> Vec<editor::Painting> {
    editor::gallery(app.path().resource_dir().ok())
}

#[tauri::command]
pub fn backdrop_copy(folder: PathBuf, from: PathBuf, name: Option<String>) -> Result<String, String> {
    editor::backdrop_copy(&folder, &from, name)
}

#[tauri::command]
pub fn recording_remove_file(folder: PathBuf, name: String) -> Result<(), String> {
    editor::remove_file(&folder, &name)
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Footage {
    /// The edit with other recordings' clips, zooms and hides appended
    /// (None when only videos came in).
    edit: Option<serde_json::Value>,
    /// Takes made from plain videos: the page adds them as clips.
    video_takes: Vec<i64>,
}

/// Videos or other Monet Shot recordings added at the end (Add clip, drops),
/// as EditorModel.addFootage. `edit` is the page's current edit.
#[tauri::command]
pub async fn add_footage(folder: PathBuf, paths: Vec<PathBuf>, edit: serde_json::Value) -> Result<Footage, String> {
    tauri::async_runtime::spawn_blocking(move || {
        use monetshot_export::imports;
        let mut p = monetshot_core::Project::load(&folder).map_err(|e| e.to_string())?;
        p.edit = serde_json::from_value(edit).map_err(|e| e.to_string())?;
        let mut out = Footage { edit: None, video_takes: vec![] };
        let me = std::fs::canonicalize(&folder).unwrap_or(folder.clone());
        for path in paths {
            if std::fs::canonicalize(&path).ok().as_ref() == Some(&me) {
                continue;
            }
            let r = if path.join("meta.json").exists() {
                monetshot_core::Project::load(&path)
                    .map_err(|e| e.to_string())
                    .and_then(|other| imports::recording(&other, &mut p).map_err(|e| e.to_string()))
                    .map(|_| out.edit = Some(serde_json::Value::Null))
            } else {
                imports::video(&path, &mut p).map_err(|e| e.to_string()).map(|i| out.video_takes.push(i))
            };
            match r {
                Ok(()) => crate::log::info(&format!("added footage: {}", path.display())),
                Err(e) => crate::log::error(&format!("add footage {}: {e}", path.display())),
            }
        }
        if out.edit.is_some() {
            out.edit = Some(serde_json::to_value(&p.edit).map_err(|e| e.to_string())?);
        }
        Ok(out)
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Renders the edit beside the recording (`<name>.mp4`, plus
/// `<name>.credits.txt` when the music asks for a credit). Emits
/// `export-progress` {folder, progress} while it runs; returns the video.
#[tauri::command]
pub async fn export_start(app: AppHandle, folder: PathBuf) -> Result<PathBuf, String> {
    use tauri::Emitter;
    tauri::async_runtime::spawn_blocking(move || {
        let p = monetshot_core::Project::load(&folder).map_err(|e| e.to_string())?;
        let out = monetshot_export::default_output(&p);
        crate::log::info(&format!("export started -> {}", out.display()));
        let last = std::sync::Mutex::new(-1.0f64);
        let progress = |f: f64| {
            // A few dozen updates are plenty for the bar.
            let mut l = last.lock().unwrap();
            if f - *l >= 0.01 || f >= 1.0 {
                *l = f;
                let _ = app.emit("export-progress", serde_json::json!({ "folder": folder, "progress": f }));
            }
        };
        let cancel = std::sync::atomic::AtomicBool::new(false);
        match monetshot_export::export(&p, &out, &progress, &cancel) {
            Ok(()) => {
                crate::log::info(&format!("export finished {}", out.display()));
                Ok(out)
            }
            Err(e) => {
                crate::log::error(&format!("export failed: {e}"));
                Err(e.to_string())
            }
        }
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Page errors land in the app's log (there's no console to read in a
/// release build, and none at all on someone else's machine).
#[tauri::command]
pub fn ui_log(window: tauri::Window, level: String, message: String) {
    let line = format!("[{}] {message}", window.label());
    if level == "error" {
        crate::log::error(&line)
    } else {
        crate::log::info(&line)
    }
}
