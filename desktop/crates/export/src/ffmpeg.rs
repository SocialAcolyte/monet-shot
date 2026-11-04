//! Finding and running ffmpeg/ffprobe: decoding video to RGBA frames at
//! given times, audio to PCM, probing files, and picking an encoder.

use crate::paint::Rgba8;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{sync_channel, Receiver};
use std::sync::{Arc, OnceLock};

#[derive(Debug)]
pub enum ExportError {
    /// ffmpeg/ffprobe not found.
    NoFfmpeg,
    /// A file has no video stream.
    NoVideo(String),
    /// ffmpeg failed (its last lines of output).
    Ffmpeg(String),
    Io(std::io::Error),
    Load(monetshot_core::project::LoadError),
    Cancelled,
}

impl std::fmt::Display for ExportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ExportError::NoFfmpeg => write!(f, "ffmpeg was not found (install it, or set MONETSHOT_FFMPEG)"),
            ExportError::NoVideo(n) => write!(f, "{n} has no video"),
            ExportError::Ffmpeg(e) => write!(f, "ffmpeg failed: {e}"),
            ExportError::Io(e) => write!(f, "{e}"),
            ExportError::Load(e) => write!(f, "{e}"),
            ExportError::Cancelled => write!(f, "cancelled"),
        }
    }
}

impl std::error::Error for ExportError {}

impl From<std::io::Error> for ExportError {
    fn from(e: std::io::Error) -> Self {
        ExportError::Io(e)
    }
}

impl From<monetshot_core::project::LoadError> for ExportError {
    fn from(e: monetshot_core::project::LoadError) -> Self {
        ExportError::Load(e)
    }
}

/// Located ffmpeg and ffprobe.
#[derive(Debug, Clone)]
pub struct Tools {
    pub ffmpeg: PathBuf,
    pub ffprobe: PathBuf,
}

fn exe(name: &str) -> String {
    if cfg!(windows) { format!("{name}.exe") } else { name.to_string() }
}

fn find(name: &str, env: &str) -> Option<PathBuf> {
    if let Some(p) = std::env::var_os(env).map(PathBuf::from).filter(|p| p.is_file()) {
        return Some(p);
    }
    // A sidecar next to the app (the Windows build bundles one).
    if let Some(dir) = std::env::current_exe().ok().and_then(|e| e.parent().map(Path::to_path_buf)) {
        for p in [dir.join(exe(name)), dir.join("ffmpeg").join(exe(name))] {
            if p.is_file() {
                return Some(p);
            }
        }
    }
    let path = std::env::var_os("PATH")?;
    let mut dirs: Vec<PathBuf> = std::env::split_paths(&path).collect();
    if cfg!(target_os = "macos") {
        dirs.extend(["/opt/homebrew/bin", "/usr/local/bin"].map(PathBuf::from));
    }
    dirs.into_iter().map(|d| d.join(exe(name))).find(|p| p.is_file())
}

/// ffmpeg and ffprobe: MONETSHOT_FFMPEG / MONETSHOT_FFPROBE, a sidecar next
/// to the executable, or PATH.
pub fn tools() -> Result<&'static Tools, ExportError> {
    static TOOLS: OnceLock<Option<Tools>> = OnceLock::new();
    TOOLS
        .get_or_init(|| Some(Tools { ffmpeg: find("ffmpeg", "MONETSHOT_FFMPEG")?, ffprobe: find("ffprobe", "MONETSHOT_FFPROBE")? }))
        .as_ref()
        .ok_or(ExportError::NoFfmpeg)
}

pub(crate) fn command(program: &Path) -> Command {
    #[allow(unused_mut)]
    let mut c = Command::new(program);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    c
}

fn tail(bytes: &[u8]) -> String {
    let s = String::from_utf8_lossy(bytes);
    let lines: Vec<&str> = s.lines().filter(|l| !l.trim().is_empty()).collect();
    lines[lines.len().saturating_sub(4)..].join(" | ")
}

// MARK: probe

/// What ffprobe says about a media file.
#[derive(Debug, Clone, PartialEq)]
pub struct Probe {
    /// Display size (rotation applied).
    pub width: u32,
    pub height: u32,
    pub duration: f64,
    pub has_video: bool,
    pub has_audio: bool,
}

pub fn probe(path: &Path) -> Result<Probe, ExportError> {
    let t = tools()?;
    let out = command(&t.ffprobe)
        .args(["-v", "error", "-show_entries", "stream=codec_type,width,height:stream_side_data=rotation:stream_tags=rotate:format=duration", "-of", "json"])
        .arg(path)
        .output()?;
    if !out.status.success() {
        return Err(ExportError::Ffmpeg(tail(&out.stderr)));
    }
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).map_err(|e| ExportError::Ffmpeg(e.to_string()))?;
    let streams = v["streams"].as_array().cloned().unwrap_or_default();
    let video = streams.iter().find(|s| s["codec_type"] == "video");
    let duration = v["format"]["duration"].as_str().and_then(|d| d.parse().ok()).unwrap_or(0.0);
    let (mut width, mut height) = video.map_or((0, 0), |s| (s["width"].as_u64().unwrap_or(0) as u32, s["height"].as_u64().unwrap_or(0) as u32));
    let rotation = video
        .and_then(|s| {
            s["side_data_list"]
                .as_array()
                .and_then(|l| l.iter().find_map(|d| d["rotation"].as_f64()))
                .or_else(|| s["tags"]["rotate"].as_str().and_then(|r| r.parse().ok()))
        })
        .unwrap_or(0.0);
    if (rotation.abs() as i64) % 180 == 90 {
        std::mem::swap(&mut width, &mut height);
    }
    Ok(Probe { width, height, duration, has_video: video.is_some(), has_audio: streams.iter().any(|s| s["codec_type"] == "audio") })
}

// MARK: video decoding

/// Frames of one video file at 60 per second from a start time, as RGBA,
/// decoded a few frames ahead on their own thread.
struct Decoder {
    child: Child,
    frames: Receiver<Arc<Rgba8>>,
    start: f64,
    /// Index of the frame in `frame` (frame n is at `start + n / FPS`).
    index: i64,
    frame: Option<Arc<Rgba8>>,
    ended: bool,
}

pub const FPS: f64 = 60.0;

impl Drop for Decoder {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// A video file read at increasing times; jumps restart the decoder there.
pub struct VideoReader {
    path: PathBuf,
    width: u32,
    height: u32,
    decoder: Option<Decoder>,
}

impl VideoReader {
    pub fn open(path: &Path) -> Result<VideoReader, ExportError> {
        let p = probe(path)?;
        if !p.has_video || p.width == 0 {
            return Err(ExportError::NoVideo(path.display().to_string()));
        }
        Ok(VideoReader { path: path.to_path_buf(), width: p.width, height: p.height, decoder: None })
    }

    pub fn size(&self) -> (u32, u32) {
        (self.width, self.height)
    }

    fn start(&mut self, at: f64) -> Result<(), ExportError> {
        let t = tools()?;
        let mut child = command(&t.ffmpeg)
            .args(["-v", "error", "-nostdin"])
            .args(["-ss", &format!("{:.6}", at.max(0.0))])
            .arg("-i")
            .arg(&self.path)
            .args(["-an", "-sn", "-vf", &format!("fps={FPS},scale=in_color_matrix=auto:in_range=auto,format=rgba")])
            .args(["-f", "rawvideo", "-pix_fmt", "rgba", "-"])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let mut out = child.stdout.take().unwrap();
        let (tx, rx) = sync_channel(4);
        let (w, h) = (self.width, self.height);
        std::thread::spawn(move || loop {
            let mut buf = vec![0u8; (w * h * 4) as usize];
            if out.read_exact(&mut buf).is_err() || tx.send(Arc::new(Rgba8::new(w, h, buf))).is_err() {
                break;
            }
        });
        self.decoder = Some(Decoder { child, frames: rx, start: at.max(0.0), index: -1, frame: None, ended: false });
        Ok(())
    }

    /// The frame showing at `time` (file time); None before 0 or after the end.
    pub fn frame_at(&mut self, time: f64) -> Result<Option<Arc<Rgba8>>, ExportError> {
        if time < -1e-6 {
            return Ok(None);
        }
        let restart = match &self.decoder {
            None => true,
            Some(d) => {
                let n = ((time - d.start) * FPS + 1e-6).floor() as i64;
                n < d.index.max(0) || n > d.index + (2.0 * FPS) as i64
            }
        };
        if restart {
            self.start(time)?;
        }
        let d = self.decoder.as_mut().unwrap();
        let n = ((time - d.start) * FPS + 1e-6).floor().max(0.0) as i64;
        while d.index < n && !d.ended {
            match d.frames.recv() {
                Ok(f) => {
                    d.frame = Some(f);
                    d.index += 1;
                }
                Err(_) => d.ended = true,
            }
        }
        // Past the end of the file: nothing (a camera file shorter than its clip),
        // except within a frame of it.
        if d.ended && d.index < n - 1 {
            return Ok(None);
        }
        Ok(d.frame.clone())
    }
}

// MARK: audio

/// The Mac's exports carry 44.1 kHz AAC.
pub const RATE: u32 = 44_100;

/// Decodes `[from, from + duration)` of a file's audio to interleaved stereo
/// f32 at `rate` (empty if it has no audio). `duration` None = to the end.
pub fn decode_audio(path: &Path, from: f64, duration: Option<f64>, channels: u32, rate: u32) -> Result<Vec<f32>, ExportError> {
    let t = tools()?;
    let mut c = command(&t.ffmpeg);
    c.args(["-v", "error", "-nostdin", "-ss", &format!("{:.6}", from.max(0.0))]);
    if let Some(d) = duration {
        c.args(["-t", &format!("{:.6}", d.max(0.0))]);
    }
    c.arg("-i").arg(path);
    run_audio(c, channels, rate)
}

/// As `decode_audio`, played at `speed` with its pitch kept (ffmpeg's
/// atempo, as the Mac's spectral time-pitch): `duration` is of the source,
/// the result lasts `duration / speed`.
pub fn decode_audio_at(path: &Path, from: f64, duration: f64, speed: f64, channels: u32, rate: u32) -> Result<Vec<f32>, ExportError> {
    if (speed - 1.0).abs() < 1e-6 {
        return decode_audio(path, from, Some(duration), channels, rate);
    }
    let t = tools()?;
    let mut c = command(&t.ffmpeg);
    c.args(["-v", "error", "-nostdin", "-ss", &format!("{:.6}", from.max(0.0)), "-t", &format!("{:.6}", duration.max(0.0))]);
    c.arg("-i").arg(path).args(["-af", &atempo(speed)]);
    run_audio(c, channels, rate)
}

/// An atempo chain for `speed`: one filter takes 0.5...2, so slower or
/// faster speeds chain several.
pub fn atempo(speed: f64) -> String {
    let mut left = speed.clamp(0.0625, 16.0);
    let mut parts = vec![];
    while left > 2.0 {
        parts.push("atempo=2".to_string());
        left /= 2.0;
    }
    while left < 0.5 {
        parts.push("atempo=0.5".to_string());
        left /= 0.5;
    }
    parts.push(format!("atempo={left:.6}"));
    parts.join(",")
}

fn run_audio(mut c: Command, channels: u32, rate: u32) -> Result<Vec<f32>, ExportError> {
    let out = c
        .args(["-vn", "-sn", "-ac", &channels.to_string(), "-ar", &rate.to_string(), "-f", "f32le", "-"])
        .stdin(Stdio::null())
        .output()?;
    if !out.status.success() {
        return Err(ExportError::Ffmpeg(tail(&out.stderr)));
    }
    Ok(out.stdout.chunks_exact(4).map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]])).collect())
}

/// Writes interleaved stereo f32 as a WAV file.
pub fn write_wav(path: &Path, samples: &[f32], rate: u32) -> std::io::Result<()> {
    let mut f = std::io::BufWriter::new(std::fs::File::create(path)?);
    let data = (samples.len() * 4) as u32;
    f.write_all(b"RIFF")?;
    f.write_all(&(36 + data).to_le_bytes())?;
    f.write_all(b"WAVEfmt ")?;
    f.write_all(&16u32.to_le_bytes())?;
    f.write_all(&3u16.to_le_bytes())?; // IEEE float
    f.write_all(&2u16.to_le_bytes())?;
    f.write_all(&rate.to_le_bytes())?;
    f.write_all(&(rate * 8).to_le_bytes())?;
    f.write_all(&8u16.to_le_bytes())?;
    f.write_all(&32u16.to_le_bytes())?;
    f.write_all(b"data")?;
    f.write_all(&data.to_le_bytes())?;
    for s in samples {
        f.write_all(&s.to_le_bytes())?;
    }
    f.flush()
}

// MARK: encoders

/// How to encode: the ffmpeg encoder and its arguments.
#[derive(Debug, Clone, PartialEq)]
pub struct Encoder {
    pub name: String,
    /// Arguments after `-c:v <name>`.
    pub args: Vec<String>,
    /// Needs frames uploaded to the GPU (vaapi).
    pub vaapi: bool,
}

fn candidates(hevc: bool) -> Vec<Encoder> {
    let e = |name: &str, args: &[&str]| Encoder { name: name.into(), args: args.iter().map(|s| s.to_string()).collect(), vaapi: false };
    let mut v = vec![];
    let codec = if hevc { "hevc" } else { "h264" };
    if cfg!(target_os = "macos") {
        v.push(e(&format!("{codec}_videotoolbox"), &["-q:v", "70", "-allow_sw", "0"]));
    } else {
        v.push(e(&format!("{codec}_nvenc"), &["-preset", "p5", "-rc", "vbr", "-cq", "19", "-b:v", "0"]));
        v.push(e(&format!("{codec}_qsv"), &["-global_quality", "20"]));
        if cfg!(windows) {
            v.push(e(&format!("{codec}_amf"), &["-quality", "quality", "-rc", "cqp", "-qp_i", "18", "-qp_p", "20"]));
        } else {
            let mut va = e(&format!("{codec}_vaapi"), &["-qp", "20"]);
            va.vaapi = true;
            v.push(va);
        }
    }
    v.push(if hevc { e("libx265", &["-preset", "medium", "-crf", "20", "-tag:v", "hvc1"]) } else { e("libx264", &["-preset", "medium", "-crf", "18"]) });
    v
}

/// Encoder arguments for the input side (vaapi needs its device first).
pub(crate) fn input_args(enc: &Encoder) -> Vec<String> {
    if enc.vaapi {
        let dev = std::env::var("MONETSHOT_VAAPI_DEVICE").unwrap_or_else(|_| "/dev/dri/renderD128".into());
        vec!["-vaapi_device".into(), dev]
    } else {
        vec![]
    }
}

/// The video filter from RGBA to what the encoder takes, BT.709.
pub(crate) fn filter(enc: &Encoder) -> String {
    let base = "scale=out_color_matrix=bt709:out_range=tv,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv";
    if enc.vaapi { format!("{base},format=nv12,hwupload") } else { format!("{base},format=yuv420p") }
}

fn works(t: &Tools, enc: &Encoder) -> bool {
    let mut c = command(&t.ffmpeg);
    c.args(["-v", "error", "-nostdin"]).args(input_args(enc));
    c.args(["-f", "lavfi", "-i", "color=c=gray:s=320x240:r=30:d=0.2", "-vf", &filter(enc), "-c:v", &enc.name]).args(&enc.args);
    c.args(["-f", "null", "-"]).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    c.status().map(|s| s.success()).unwrap_or(false)
}

/// The best encoder that actually works here: a hardware one when present,
/// libx264 (libx265 for HEVC) otherwise. MONETSHOT_ENCODER forces one by name.
pub fn pick_encoder(hevc: bool) -> Result<Encoder, ExportError> {
    static PICKED: OnceLock<std::sync::Mutex<Vec<(bool, Encoder)>>> = OnceLock::new();
    let cache = PICKED.get_or_init(Default::default);
    if let Some((_, e)) = cache.lock().unwrap().iter().find(|(h, _)| *h == hevc) {
        return Ok(e.clone());
    }
    let t = tools()?;
    let list = candidates(hevc);
    let forced = std::env::var("MONETSHOT_ENCODER").ok();
    let chosen = list
        .iter()
        .filter(|e| forced.as_ref().map_or(true, |f| &e.name == f))
        .find(|e| works(t, e))
        .cloned()
        .or_else(|| list.last().cloned())
        .unwrap();
    cache.lock().unwrap().push((hevc, chosen.clone()));
    Ok(chosen)
}
