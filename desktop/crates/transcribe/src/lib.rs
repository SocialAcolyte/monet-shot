//! What you said, as words with times, heard on this computer: whisper.cpp
//! (through whisper-rs) with a small multilingual model downloaded on first
//! use, checked against its SHA-256 and kept in the app's data folder.
//! Nothing leaves the machine but that one download. The Mac does the same
//! job with Apple's on-device speech (`Sources/MonetShot/Speech`); both
//! write the take's `transcript.json` (`monetshot_core::captions`).

use monetshot_core::captions::{Transcript, TranscriptWord};
use monetshot_core::Take;
use sha2::{Digest, Sha256};
use std::fmt;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

/// The model: whisper "base", multilingual, 5-bit quantised (57 MB).
pub struct Model {
    pub file: &'static str,
    pub url: &'static str,
    pub sha256: &'static str,
    pub size: u64,
}

pub const MODEL: Model = Model {
    file: "ggml-base-q5_1.bin",
    url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin",
    sha256: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898",
    size: 59_707_625,
};

/// The audio whisper hears: 16 kHz mono.
pub const RATE: u32 = 16_000;

#[derive(Debug)]
pub enum Error {
    Cancelled,
    Download(String),
    Checksum,
    NoVoice,
    Audio(String),
    Whisper(String),
    Io(std::io::Error),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Cancelled => write!(f, "cancelled"),
            Error::Download(e) => write!(f, "couldn't download the speech model: {e}"),
            Error::Checksum => write!(f, "the speech model didn't download whole; try again"),
            Error::NoVoice => write!(f, "this take has no voice"),
            Error::Audio(e) => write!(f, "couldn't read the voice: {e}"),
            Error::Whisper(e) => write!(f, "transcription failed: {e}"),
            Error::Io(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e)
    }
}

/// Called with progress, from any thread.
pub type Progress = Arc<dyn Fn(Stage) + Send + Sync>;

/// Where we are, for a progress bar.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Stage {
    /// Fetching the model (first use only), 0...1.
    Downloading(f64),
    /// Listening, 0...1.
    Transcribing(f64),
}

/// The models folder: `MONETSHOT_HOME/models`, else the user's local data
/// folder (`~/.local/share/MonetShot/models`, `%LOCALAPPDATA%\MonetShot\models`).
pub fn models_dir() -> PathBuf {
    if let Some(h) = std::env::var_os("MONETSHOT_HOME").filter(|h| !h.is_empty()) {
        return PathBuf::from(h).join("models");
    }
    dirs::data_local_dir().unwrap_or_else(std::env::temp_dir).join("MonetShot").join("models")
}

/// The model file (MONETSHOT_WHISPER_MODEL overrides, for tests).
pub fn model_path() -> PathBuf {
    if let Some(p) = std::env::var_os("MONETSHOT_WHISPER_MODEL").filter(|p| !p.is_empty()) {
        return PathBuf::from(p);
    }
    models_dir().join(MODEL.file)
}

/// True when the model is here and was checked.
pub fn model_ready() -> bool {
    let p = model_path();
    p.is_file() && (std::env::var_os("MONETSHOT_WHISPER_MODEL").is_some() || checked_marker(&p).is_file())
}

fn checked_marker(p: &Path) -> PathBuf {
    p.with_extension("bin.sha256")
}

pub fn sha256_file(p: &Path) -> std::io::Result<String> {
    let mut f = std::fs::File::open(p)?;
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(h.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

fn curl() -> Command {
    #[allow(unused_mut)]
    let mut c = Command::new(if cfg!(windows) { "curl.exe" } else { "curl" });
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    c
}

/// The model, downloading it first if it isn't here (with progress, checked
/// against its SHA-256). `cancel` stops the download and removes the part.
pub fn ensure_model(progress: &Progress, cancel: &AtomicBool) -> Result<PathBuf, Error> {
    let path = model_path();
    if model_ready() {
        return Ok(path);
    }
    std::fs::create_dir_all(path.parent().unwrap_or(Path::new(".")))?;
    // A whole file from before whose check never got written: check it now.
    if path.is_file() && std::fs::metadata(&path)?.len() == MODEL.size && sha256_file(&path)? == MODEL.sha256 {
        std::fs::write(checked_marker(&path), MODEL.sha256)?;
        return Ok(path);
    }
    let part = path.with_extension("bin.part");
    let _ = std::fs::remove_file(&part);
    log::info!("downloading the speech model to {}", path.display());
    let mut child = curl()
        .args(["--fail", "--location", "--silent", "--show-error", "--retry", "3", "-o"])
        .arg(&part)
        .arg(MODEL.url)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| Error::Download(format!("curl: {e}")))?;
    progress(Stage::Downloading(0.0));
    let status = loop {
        if cancel.load(Ordering::Relaxed) {
            let _ = child.kill();
            let _ = child.wait();
            let _ = std::fs::remove_file(&part);
            return Err(Error::Cancelled);
        }
        if let Some(s) = child.try_wait()? {
            break s;
        }
        let got = std::fs::metadata(&part).map(|m| m.len()).unwrap_or(0);
        progress(Stage::Downloading((got as f64 / MODEL.size as f64).min(0.99)));
        std::thread::sleep(Duration::from_millis(200));
    };
    if !status.success() {
        let mut e = String::new();
        if let Some(mut s) = child.stderr.take() {
            let _ = s.read_to_string(&mut e);
        }
        let _ = std::fs::remove_file(&part);
        return Err(Error::Download(e.trim().lines().last().unwrap_or("no connection").to_string()));
    }
    if sha256_file(&part)? != MODEL.sha256 {
        let _ = std::fs::remove_file(&part);
        return Err(Error::Checksum);
    }
    std::fs::rename(&part, &path)?;
    std::fs::write(checked_marker(&path), MODEL.sha256)?;
    progress(Stage::Downloading(1.0));
    log::info!("speech model ready");
    Ok(path)
}

/// `path`'s sound as whisper wants it (ffmpeg: 16 kHz mono floats).
pub fn decode(path: &Path) -> Result<Vec<f32>, Error> {
    monetshot_export::ffmpeg::decode_audio(path, 0.0, None, 1, RATE).map_err(|e| Error::Audio(e.to_string()))
}

/// Bracketed non-speech marks whisper writes ("[BLANK_AUDIO]", "(music)").
fn is_mark(s: &str) -> bool {
    (s.starts_with('[') && s.ends_with(']')) || (s.starts_with('(') && s.ends_with(')')) || (s.starts_with('*') && s.ends_with('*'))
}

/// Words in `audio` (16 kHz mono) with times in seconds from its start, and
/// the language heard. `language`: a code ("en") or None to detect it.
pub fn transcribe(audio: &[f32], language: Option<&str>, model: &Path, progress: &Progress, cancel: Arc<AtomicBool>) -> Result<(Vec<TranscriptWord>, Option<String>), Error> {
    if audio.len() < (RATE / 4) as usize {
        return Ok((vec![], language.map(String::from)));
    }
    let ctx = WhisperContext::new_with_params(model, WhisperContextParameters::default()).map_err(|e| Error::Whisper(e.to_string()))?;
    let mut state = ctx.create_state().map_err(|e| Error::Whisper(e.to_string()))?;
    let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).clamp(1, 8);
    params.set_n_threads(threads as i32);
    params.set_language(Some(language.unwrap_or("auto")));
    params.set_translate(false);
    params.set_print_special(false);
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_timestamps(false);
    // One word per segment, each with its own times.
    params.set_token_timestamps(true);
    params.set_split_on_word(true);
    params.set_max_len(1);
    let c = cancel.clone();
    params.set_abort_callback_safe(move || c.load(Ordering::Relaxed));
    let p = progress.clone();
    params.set_progress_callback_safe(move |n: i32| p(Stage::Transcribing((n as f64 / 100.0).clamp(0.0, 0.99))));
    progress(Stage::Transcribing(0.0));
    let result = state.full(params, audio);
    if cancel.load(Ordering::Relaxed) {
        return Err(Error::Cancelled);
    }
    result.map_err(|e| Error::Whisper(e.to_string()))?;
    let mut words: Vec<TranscriptWord> = vec![];
    for seg in state.as_iter() {
        let text = seg.to_str_lossy().map(|t| t.trim().to_string()).unwrap_or_default();
        if text.is_empty() || is_mark(&text) {
            continue;
        }
        let (t0, t1) = (seg.start_timestamp() as f64 / 100.0, seg.end_timestamp() as f64 / 100.0);
        // Punctuation on its own belongs to the word before it.
        if text.chars().all(|c| c.is_ascii_punctuation()) {
            if let Some(last) = words.last_mut() {
                last.text.push_str(&text);
                continue;
            }
        }
        words.push(TranscriptWord { text, start: t0, end: t1.max(t0) });
    }
    words.sort_by(|a, b| a.start.total_cmp(&b.start));
    let lang = whisper_rs::get_lang_str(state.full_lang_id_from_state()).map(String::from).or_else(|| language.map(String::from));
    progress(Stage::Transcribing(1.0));
    Ok((words, lang))
}

/// The take's voice file, if it has one.
pub fn voice_path(take: &Take) -> Option<PathBuf> {
    take.meta.voice.as_ref().map(|v| take.folder.join(v)).filter(|p| p.is_file())
}

/// Transcribes a take's voice (downloading the model first if needed) and
/// saves its `transcript.json`. Word times are the take's own.
pub fn transcribe_take(take: &Take, language: Option<&str>, progress: &Progress, cancel: Arc<AtomicBool>) -> Result<Transcript, Error> {
    let voice = voice_path(take).ok_or(Error::NoVoice)?;
    let model = ensure_model(progress, &cancel)?;
    let audio = decode(&voice)?;
    let offset = take.meta.voice_offset.unwrap_or(0.0);
    let (mut words, lang) = transcribe(&audio, language, &model, progress, cancel)?;
    for w in &mut words {
        w.start += offset;
        w.end += offset;
    }
    let t = Transcript { words, language: lang, engine: Some("whisper".into()), ..Default::default() };
    t.save(&take.folder)?;
    log::info!("transcribed {}: {} words", take.folder.display(), t.words.len());
    Ok(t)
}

/// Word error rate of `heard` against `expected` (case and punctuation ignored).
pub fn word_error_rate(expected: &str, heard: &str) -> f64 {
    let norm = |s: &str| -> Vec<String> {
        s.split_whitespace()
            .map(|w| w.chars().filter(|c| c.is_alphanumeric() || *c == '\'').collect::<String>().to_lowercase())
            .filter(|w| !w.is_empty())
            .collect()
    };
    let (a, b) = (norm(expected), norm(heard));
    let mut d: Vec<usize> = (0..=b.len()).collect();
    for i in 1..=a.len() {
        let mut prev = d[0];
        d[0] = i;
        for j in 1..=b.len() {
            let cur = d[j];
            d[j] = if a[i - 1] == b[j - 1] { prev } else { 1 + prev.min(d[j]).min(d[j - 1]) };
            prev = cur;
        }
    }
    d[b.len()] as f64 / a.len().max(1) as f64
}
