//! Your voice, heard: the microphone choice for new recordings, the
//! transcription settings, and transcribing takes on this computer
//! (monetshot-transcribe: whisper, its model downloaded on first use).
//! The Mac keeps the same settings in UserDefaults (micDevice,
//! transcribeLanguage, autoTranscribe, writeSubtitles).

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter};

use monetshot_transcribe as tr;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    /// The microphone for new recordings ("default" = the system's), None = off.
    pub mic: Option<String>,
    /// "auto" or a language code ("en", "fr", …).
    pub language: String,
    /// Transcribe a take with a voice as soon as its editor opens.
    pub auto_transcribe: bool,
    /// Write `<name>.srt` beside every export that has words.
    pub write_subtitles: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings { mic: None, language: "auto".into(), auto_transcribe: true, write_subtitles: true }
    }
}

fn file() -> PathBuf {
    monetshot_core::paths::support_dir().join("speech.json")
}

pub fn settings() -> Settings {
    std::fs::read(file()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

fn save(s: &Settings) -> Result<(), String> {
    let p = file();
    if let Some(d) = p.parent() {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    let tmp = p.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(s).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &p).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn speech_settings() -> Settings {
    settings()
}

#[tauri::command]
pub fn speech_set(settings: Settings) -> Result<(), String> {
    save(&settings)
}

#[derive(Serialize)]
pub struct Mic {
    id: String,
    name: String,
}

/// The microphones, the system's default first.
#[tauri::command]
pub async fn microphones() -> Result<Vec<Mic>, String> {
    tauri::async_runtime::spawn_blocking(|| {
        let mut v: Vec<Mic> = monetshot_capture::microphones().map_err(|e| e.to_string())?.into_iter().map(|d| Mic { id: d.id, name: d.name }).collect();
        if !v.iter().any(|m| m.id == "default") {
            v.insert(0, Mic { id: "default".into(), name: "Default microphone".into() });
        }
        Ok(v)
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Running transcriptions, by recording folder: cancel flags.
static RUNNING: Mutex<Option<HashMap<PathBuf, Arc<AtomicBool>>>> = Mutex::new(None);

fn key(folder: &Path) -> PathBuf {
    std::fs::canonicalize(folder).unwrap_or_else(|_| folder.to_path_buf())
}

/// Transcribes take `take` of the recording at `folder` (its voice must be
/// there) and saves its transcript.json. Emits `transcribe-progress`
/// {folder, take, stage: "download"|"listen", progress}. Returns the
/// transcript as saved.
#[tauri::command]
pub async fn transcribe(app: AppHandle, folder: PathBuf, take: usize, language: Option<String>) -> Result<monetshot_core::Transcript, String> {
    let cancel = Arc::new(AtomicBool::new(false));
    RUNNING.lock().unwrap().get_or_insert_with(HashMap::new).insert(key(&folder), cancel.clone());
    let f = folder.clone();
    let result = tauri::async_runtime::spawn_blocking(move || {
        let p = monetshot_core::Project::load(&f).map_err(|e| e.to_string())?;
        let t = p.takes.get(take).ok_or("no such take")?;
        let lang = language.or_else(|| Some(settings().language)).filter(|l| !l.is_empty() && l != "auto");
        let (app2, f2) = (app.clone(), f.clone());
        let last = Arc::new(Mutex::new((String::new(), -1.0f64)));
        let progress: tr::Progress = Arc::new(move |s: tr::Stage| {
            let (stage, x) = match s {
                tr::Stage::Downloading(x) => ("download", x),
                tr::Stage::Transcribing(x) => ("listen", x),
            };
            let mut l = last.lock().unwrap();
            if l.0 != stage || x - l.1 >= 0.01 || x >= 1.0 {
                *l = (stage.to_string(), x);
                let _ = app2.emit("transcribe-progress", serde_json::json!({ "folder": f2, "take": take, "stage": stage, "progress": x }));
            }
        });
        crate::log::info(&format!("transcribe {} take {take} ({})", f.display(), lang.as_deref().unwrap_or("auto")));
        tr::transcribe_take(t, lang.as_deref(), &progress, cancel).map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())
    .and_then(|r| r);
    RUNNING.lock().unwrap().get_or_insert_with(HashMap::new).remove(&key(&folder));
    match &result {
        Ok(t) => crate::log::info(&format!("transcribed take {take}: {} words", t.words.len())),
        Err(e) => crate::log::error(&format!("transcribe: {e}")),
    }
    result
}

#[tauri::command]
pub fn transcribe_cancel(folder: PathBuf) {
    if let Some(c) = RUNNING.lock().unwrap().get_or_insert_with(HashMap::new).get(&key(&folder)) {
        c.store(true, Ordering::Relaxed);
    }
}

/// Saves a fixed transcript (a word respelled or dropped in the editor).
#[tauri::command]
pub fn transcript_save(folder: PathBuf, take: usize, transcript: monetshot_core::Transcript) -> Result<(), String> {
    let p = monetshot_core::Project::load(&folder).map_err(|e| e.to_string())?;
    let t = p.takes.get(take).ok_or("no such take")?;
    transcript.save(&t.folder).map_err(|e| e.to_string())
}

/// After an export: `<name>.srt` beside it when there are words and the
/// setting says so (a stale one removed otherwise).
pub fn after_export(project: &monetshot_core::Project, video: &Path) {
    if !settings().write_subtitles {
        return;
    }
    match monetshot_export::subtitles::write_srt(project, video) {
        Ok(Some(p)) => crate::log::info(&format!("subtitles written {}", p.display())),
        Ok(None) => {}
        Err(e) => crate::log::error(&format!("subtitles: {e}")),
    }
}
