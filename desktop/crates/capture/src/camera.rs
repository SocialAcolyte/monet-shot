//! The webcam and microphone, for you on camera. One shared ffmpeg process,
//! as the Mac's one `AVCaptureSession`: the live preview (JPEG frames for
//! the bubble and the editor) and the recorded file come from the same
//! capture, because cameras are exclusive on v4l2 and most Windows drivers.
//!
//! acquire → preview runs; record(file) → the process restarts with a file
//! output too (one short blink in the preview); stop → back to preview only;
//! the last hold dropped → the camera turns off.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::ffmpeg::{ffmpeg, Ffmpeg, NoWindow};
use crate::CaptureError;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Device {
    /// What to pass back in `CameraChoice` (a path, an index, a name).
    pub id: String,
    pub name: String,
}

/// None = the system default. `mic: Some("")` records the camera silent.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CameraChoice {
    pub camera: Option<String>,
    pub mic: Option<String>,
}

/// Receives preview frames: JPEG, at most 640 px wide, ~30 fps.
pub type PreviewSink = Arc<dyn Fn(&[u8]) + Send + Sync>;

const PREVIEW_FPS: u32 = 30;

struct Running {
    child: Child,
    stdin: Option<ChildStdin>,
    /// The file being written, if recording.
    file: Option<PathBuf>,
    first: mpsc::Receiver<Instant>,
}

#[derive(Default)]
struct State {
    choice: CameraChoice,
    next_id: u64,
    running: Option<Running>,
}

static STATE: Mutex<Option<State>> = Mutex::new(None);
/// Separate from STATE: the reader threads take these while STATE is held
/// by a caller waiting on ffmpeg, which must keep draining its pipes.
static SINKS: Mutex<Vec<(u64, Option<PreviewSink>)>> = Mutex::new(Vec::new());
static LAST_ERROR: Mutex<Option<String>> = Mutex::new(None);

fn with<R>(f: impl FnOnce(&mut State) -> R) -> R {
    let mut g = STATE.lock().unwrap();
    f(g.get_or_insert_with(State::default))
}

pub struct Camera;

impl Camera {
    /// Turns the camera on (or joins it if it's on). Balance by dropping the hold.
    pub fn acquire(choice: &CameraChoice, preview: Option<PreviewSink>) -> Result<CameraHold, CaptureError> {
        let ff = ffmpeg()?;
        let id = with(|s| -> Result<u64, CaptureError> {
            let restart = s.running.is_some() && s.choice != *choice && s.running.as_ref().is_some_and(|r| r.file.is_none());
            if s.running.as_ref().is_some_and(|r| r.file.is_some()) && s.choice != *choice {
                log::info!("camera: busy recording; keeping the current camera");
            } else {
                s.choice = choice.clone();
            }
            if restart {
                stop_process(s.running.take());
            }
            if s.running.is_none() {
                s.running = Some(spawn(&ff, &s.choice, None)?);
                wait_first(s, Duration::from_secs(8))?;
            }
            s.next_id += 1;
            let id = s.next_id;
            SINKS.lock().unwrap().push((id, preview));
            Ok(id)
        })?;
        Ok(CameraHold { id, ff })
    }

    /// True while some hold keeps it on.
    pub fn is_on() -> bool {
        with(|s| s.running.is_some())
    }
}

pub struct CameraHold {
    id: u64,
    ff: Ffmpeg,
}

impl CameraHold {
    /// Starts writing `path` (H.264 + AAC from the mic). Returns the moment
    /// its first frame arrived: the time the file starts.
    pub fn record(&self, path: &Path) -> Result<Instant, CaptureError> {
        with(|s| {
            if s.running.as_ref().is_some_and(|r| r.file.is_some()) {
                return Err(CaptureError::Other("the camera is already recording".into()));
            }
            let _ = std::fs::remove_file(path);
            stop_process(s.running.take());
            s.running = Some(spawn(&self.ff, &s.choice, Some(path))?);
            match wait_first(s, Duration::from_secs(8)) {
                Ok(at) => {
                    log::info!("camera recording: {}", path.display());
                    Ok(at)
                }
                Err(e) => {
                    let _ = std::fs::remove_file(path);
                    // Back to preview only, if anyone is watching.
                    s.running = spawn(&self.ff, &s.choice, None).ok();
                    Err(e)
                }
            }
        })
    }

    /// Stops the file and returns it (None if nothing usable was written).
    pub fn stop(&self) -> Result<Option<PathBuf>, CaptureError> {
        with(|s| {
            let Some(r) = s.running.take() else { return Ok(None) };
            let file = r.file.clone();
            if file.is_none() {
                s.running = Some(r);
                return Ok(None);
            }
            stop_process(Some(r));
            let sinks = SINKS.lock().unwrap();
            if sinks.len() > 1 || sinks.iter().any(|(_, p)| p.is_some()) {
                s.running = spawn(&self.ff, &s.choice, None).ok();
            }
            Ok(file.filter(|f| std::fs::metadata(f).map(|m| m.len() > 0).unwrap_or(false)))
        })
    }
}

impl Drop for CameraHold {
    fn drop(&mut self) {
        with(|s| {
            let mut sinks = SINKS.lock().unwrap();
            sinks.retain(|(id, _)| *id != self.id);
            if sinks.is_empty() {
                drop(sinks);
                stop_process(s.running.take());
                log::info!("camera off");
            }
        })
    }
}

/// Waits for the first preview frame of the process just spawned.
fn wait_first(s: &mut State, timeout: Duration) -> Result<Instant, CaptureError> {
    let r = s.running.as_mut().expect("running");
    match r.first.recv_timeout(timeout) {
        Ok(at) => Ok(at),
        Err(_) => {
            let r = s.running.take();
            stop_process(r);
            // Let the stderr reader catch ffmpeg's last words.
            std::thread::sleep(Duration::from_millis(100));
            let detail = LAST_ERROR.lock().unwrap().take().unwrap_or_else(|| "no picture from the camera".into());
            Err(CaptureError::Other(detail))
        }
    }
}

fn spawn(ff: &Ffmpeg, choice: &CameraChoice, file: Option<&Path>) -> Result<Running, CaptureError> {
    let mut cmd = Command::new(&ff.ffmpeg);
    cmd.args(["-hide_banner", "-loglevel", "error", "-y"]).no_window();
    let input = Input::for_choice(choice);
    cmd.args(&input.args);
    // The preview: small JPEGs on stdout.
    cmd.args(["-map", "0:v", "-vf", &format!("fps={PREVIEW_FPS},scale='min(640,iw)':-2"), "-q:v", "6", "-f", "mjpeg", "pipe:1"]);
    if let Some(path) = file {
        let enc = ff.best_encoder();
        cmd.args(["-map", "0:v"]).args(enc.args(30));
        if let Some(a) = &input.audio {
            cmd.args(["-map", a, "-c:a", "aac", "-b:a", "160k"]);
        }
        cmd.args(["-movflags", "+faststart"]).arg(path);
    }
    cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(|e| CaptureError::Ffmpeg(format!("could not start ffmpeg: {e}")))?;
    let stdin = child.stdin.take();
    let mut stdout = child.stdout.take().expect("stdout");
    let mut stderr = child.stderr.take().expect("stderr");
    std::thread::spawn(move || {
        let mut s = String::new();
        let _ = stderr.read_to_string(&mut s);
        let s = s.trim().to_string();
        if !s.is_empty() {
            log::error!("camera ffmpeg: {s}");
            *LAST_ERROR.lock().unwrap() = Some(s.lines().last().unwrap_or_default().to_string());
        }
    });
    let (tx, rx) = mpsc::channel();
    std::thread::Builder::new()
        .name("monetshot-camera".into())
        .spawn(move || read_jpegs(&mut stdout, tx))
        .map_err(|e| CaptureError::Other(e.to_string()))?;
    Ok(Running { child, stdin, file: file.map(Path::to_path_buf), first: rx })
}

/// Splits ffmpeg's MJPEG stream into frames (SOI … EOI; 0xFF inside the
/// data is always stuffed, so EOI can't appear early) and hands them out.
fn read_jpegs(out: &mut impl Read, first: mpsc::Sender<Instant>) {
    let mut buf: Vec<u8> = Vec::with_capacity(1 << 20);
    let mut chunk = vec![0u8; 1 << 16];
    let mut sent_first = false;
    loop {
        let n = match out.read(&mut chunk) {
            Ok(0) | Err(_) => return,
            Ok(n) => n,
        };
        buf.extend_from_slice(&chunk[..n]);
        while let Some((start, end)) = next_jpeg(&buf) {
            if !sent_first {
                sent_first = true;
                let _ = first.send(Instant::now());
            }
            let frame = &buf[start..end];
            let sinks: Vec<PreviewSink> = SINKS.lock().unwrap().iter().filter_map(|(_, p)| p.clone()).collect();
            for sink in sinks {
                sink(frame);
            }
            buf.drain(..end);
        }
    }
}

fn next_jpeg(b: &[u8]) -> Option<(usize, usize)> {
    let start = b.windows(2).position(|w| w == [0xFF, 0xD8])?;
    let end = b[start + 2..].windows(2).position(|w| w == [0xFF, 0xD9])? + start + 4;
    Some((start, end))
}

/// Ends ffmpeg cleanly ('q' on stdin, so the file gets its index), or kills it.
fn stop_process(r: Option<Running>) {
    let Some(mut r) = r else { return };
    if let Some(mut stdin) = r.stdin.take() {
        let _ = stdin.write_all(b"q");
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if let Ok(Some(_)) = r.child.try_wait() {
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    log::error!("camera: ffmpeg didn't stop; killing it");
    let _ = r.child.kill();
    let _ = r.child.wait();
}

/// The ffmpeg input options for this OS, and the audio stream to map.
struct Input {
    args: Vec<String>,
    audio: Option<String>,
}

impl Input {
    fn for_choice(c: &CameraChoice) -> Input {
        let want_mic = c.mic.as_deref() != Some("");
        let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
        if cfg!(target_os = "linux") {
            let cam = c.camera.clone().or_else(|| cameras().ok().and_then(|v| v.first().map(|d| d.id.clone()))).unwrap_or("/dev/video0".into());
            let mut args = s(&["-f", "v4l2", "-thread_queue_size", "512", "-input_format", "mjpeg", "-framerate", "30", "-video_size", "1920x1080", "-i"]);
            args.push(cam);
            let mut audio = None;
            if want_mic {
                args.extend(s(&["-f", "pulse", "-thread_queue_size", "512", "-i"]));
                args.push(c.mic.clone().unwrap_or("default".into()));
                audio = Some("1:a".into());
            }
            Input { args, audio }
        } else if cfg!(windows) {
            let cam = c.camera.clone().or_else(|| cameras().ok().and_then(|v| v.first().map(|d| d.id.clone())));
            let mic = if want_mic { c.mic.clone().or_else(|| microphones().ok().and_then(|v| v.first().map(|d| d.id.clone()))) } else { None };
            let mut spec = format!("video={}", cam.unwrap_or_default());
            if let Some(m) = &mic {
                spec.push_str(&format!(":audio={m}"));
            }
            let mut args = s(&["-f", "dshow", "-rtbufsize", "256M", "-video_size", "1920x1080", "-framerate", "30", "-i"]);
            args.push(spec);
            Input { args, audio: mic.map(|_| "0:a".into()) }
        } else {
            let cam = c.camera.clone().unwrap_or("0".into());
            let mic = if want_mic { Some(c.mic.clone().unwrap_or("0".into())) } else { None };
            let mut args = s(&["-f", "avfoundation", "-framerate", "30", "-video_size", "1920x1080", "-pixel_format", "nv12", "-i"]);
            args.push(format!("{cam}:{}", mic.clone().unwrap_or("none".into())));
            Input { args, audio: mic.map(|_| "0:a".into()) }
        }
    }
}

/// Cameras, the default first where the system says which it is.
pub fn cameras() -> Result<Vec<Device>, CaptureError> {
    if cfg!(target_os = "linux") {
        return Ok(v4l2_cameras());
    }
    Ok(list_ffmpeg_devices()?.0)
}

pub fn microphones() -> Result<Vec<Device>, CaptureError> {
    if cfg!(target_os = "linux") {
        return Ok(pulse_sources());
    }
    Ok(list_ffmpeg_devices()?.1)
}

/// Capture nodes in /sys: each camera has a metadata node too (index 1), skip it.
fn v4l2_cameras() -> Vec<Device> {
    let mut out: Vec<(u32, Device)> = Vec::new();
    let Ok(dir) = std::fs::read_dir("/sys/class/video4linux") else { return Vec::new() };
    for e in dir.flatten() {
        let node = e.file_name().to_string_lossy().to_string();
        let Some(n) = node.strip_prefix("video").and_then(|n| n.parse::<u32>().ok()) else { continue };
        let read = |f: &str| std::fs::read_to_string(e.path().join(f)).map(|s| s.trim().to_string()).unwrap_or_default();
        if read("index") != "0" && !read("index").is_empty() {
            continue;
        }
        out.push((n, Device { id: format!("/dev/{node}"), name: read("name") }));
    }
    out.sort_by_key(|(n, _)| *n);
    out.into_iter().map(|(_, d)| d).collect()
}

/// Microphones from PipeWire/Pulse (`pactl`), monitors of outputs left out.
fn pulse_sources() -> Vec<Device> {
    let Ok(o) = Command::new("pactl").args(["list", "short", "sources"]).output() else {
        return vec![Device { id: "default".into(), name: "Default microphone".into() }];
    };
    let mut v: Vec<Device> = String::from_utf8_lossy(&o.stdout)
        .lines()
        .filter_map(|l| l.split('\t').nth(1).map(str::to_string))
        .filter(|n| !n.ends_with(".monitor"))
        .map(|n| Device { name: n.clone(), id: n })
        .collect();
    v.insert(0, Device { id: "default".into(), name: "Default microphone".into() });
    v
}

/// dshow and avfoundation both list devices on stderr.
fn list_ffmpeg_devices() -> Result<(Vec<Device>, Vec<Device>), CaptureError> {
    let ff = ffmpeg()?;
    let mut c = Command::new(&ff.ffmpeg);
    c.arg("-hide_banner").no_window();
    if cfg!(windows) {
        c.args(["-list_devices", "true", "-f", "dshow", "-i", "dummy"]);
    } else {
        c.args(["-f", "avfoundation", "-list_devices", "true", "-i", ""]);
    }
    let o = c.stdin(Stdio::null()).output()?;
    let text = String::from_utf8_lossy(&o.stderr);
    Ok(if cfg!(windows) { parse_dshow(&text) } else { parse_avfoundation(&text) })
}

fn parse_dshow(text: &str) -> (Vec<Device>, Vec<Device>) {
    let (mut video, mut audio) = (Vec::new(), Vec::new());
    for line in text.lines() {
        let Some(a) = line.find('"') else { continue };
        let Some(b) = line[a + 1..].find('"') else { continue };
        let name = &line[a + 1..a + 1 + b];
        if line.contains("Alternative name") {
            continue;
        }
        let d = Device { id: name.to_string(), name: name.to_string() };
        if line.trim_end().ends_with("(video)") {
            video.push(d);
        } else if line.trim_end().ends_with("(audio)") {
            audio.push(d);
        }
    }
    (video, audio)
}

fn parse_avfoundation(text: &str) -> (Vec<Device>, Vec<Device>) {
    let (mut video, mut audio) = (Vec::new(), Vec::new());
    let mut in_audio = false;
    for line in text.lines() {
        if line.contains("AVFoundation video devices") {
            in_audio = false;
            continue;
        }
        if line.contains("AVFoundation audio devices") {
            in_audio = true;
            continue;
        }
        // "[AVFoundation indev @ 0x…] [0] FaceTime HD Camera"
        let Some(rest) = line.rsplit_once("] [").map(|(_, r)| r) else { continue };
        let Some((idx, name)) = rest.split_once("] ") else { continue };
        if name.starts_with("Capture screen") {
            continue;
        }
        let d = Device { id: idx.to_string(), name: name.to_string() };
        if in_audio { audio.push(d) } else { video.push(d) }
    }
    (video, audio)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_jpegs() {
        let b = [0u8, 0xFF, 0xD8, 1, 0xFF, 0x00, 2, 0xFF, 0xD9, 0xFF, 0xD8, 3];
        assert_eq!(next_jpeg(&b), Some((1, 9)));
        assert_eq!(next_jpeg(&b[9..]), None);
    }

    #[test]
    fn parses_dshow() {
        let t = r#"[dshow @ 0] "Integrated Camera" (video)
[dshow @ 0]   Alternative name "@device_pnp_\\?\usb#vid"
[dshow @ 0] "Microphone Array (Realtek(R) Audio)" (audio)"#;
        let (v, a) = parse_dshow(t);
        assert_eq!(v[0].name, "Integrated Camera");
        assert_eq!(a[0].id, "Microphone Array (Realtek(R) Audio)");
    }

    #[test]
    fn parses_avfoundation() {
        let t = "[AVFoundation indev @ 0x1] AVFoundation video devices:\n[AVFoundation indev @ 0x1] [0] FaceTime HD Camera\n[AVFoundation indev @ 0x1] [1] Capture screen 0\n[AVFoundation indev @ 0x1] AVFoundation audio devices:\n[AVFoundation indev @ 0x1] [0] MacBook Pro Microphone";
        let (v, a) = parse_avfoundation(t);
        assert_eq!(v, vec![Device { id: "0".into(), name: "FaceTime HD Camera".into() }]);
        assert_eq!(a[0].name, "MacBook Pro Microphone");
    }
}
