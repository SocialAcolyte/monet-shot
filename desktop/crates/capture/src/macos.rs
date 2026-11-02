//! macos-dev: lets the desktop app run on the dev Mac (ms-app's loop). Not
//! shipped; the Swift app is the Mac product.
//!
//! Displays only (avfoundation can't capture a window), recorded by ffmpeg
//! straight to screen.mp4 without the cursor. The pointer, buttons and
//! Shift are polled 120 times a second from CoreGraphics' state, as the
//! Mac's CursorTracker does, which needs no permission. Recording the
//! screen does: the terminal (or the dev app) needs Screen Recording.

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use core_graphics::display::CGDisplay;

use crate::ffmpeg::{ffmpeg, Ffmpeg};
use crate::pointer::Bar;
use crate::session::{self, Capture, Shared, Video};
use crate::{
    Backend, Capabilities, CaptureError, CursorSupport, EventSink, Picked, Recording, Rect, Source, SourceId, SourceKind,
    StartOptions, Thumbnail,
};

pub struct MacBackend;

impl MacBackend {
    pub fn new() -> Self {
        MacBackend
    }
}

impl Default for MacBackend {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Clone, Debug)]
struct Display {
    id: u32,
    /// avfoundation's device index for this screen.
    avf: String,
    /// Points, global, origin top-left of the main display.
    bounds: Rect,
    pixels: (u32, u32),
    title: String,
}

fn displays(ff: &Ffmpeg) -> Result<Vec<Display>, CaptureError> {
    let ids = CGDisplay::active_displays().map_err(|e| CaptureError::Other(format!("no displays ({e})")))?;
    let screens = avf_screens(ff)?;
    let mut out = Vec::new();
    for (k, id) in ids.into_iter().enumerate() {
        let d = CGDisplay::new(id);
        let b = d.bounds();
        let (pw, ph) = d.display_mode().map(|m| (m.pixel_width() as u32, m.pixel_height() as u32)).unwrap_or((b.size.width as u32, b.size.height as u32));
        let Some(avf) = screens.get(k).cloned() else { continue };
        out.push(Display {
            id,
            avf,
            bounds: Rect { x: b.origin.x, y: b.origin.y, width: b.size.width, height: b.size.height },
            pixels: (pw, ph),
            title: format!("{} ({pw}×{ph})", if d.is_main() { "Main display".to_string() } else { format!("Display {}", k + 1) }),
        });
    }
    Ok(out)
}

/// "[3] Capture screen 0" → index "3" for screen 0, in screen order.
fn avf_screens(ff: &Ffmpeg) -> Result<Vec<String>, CaptureError> {
    let o = ff_cmd(ff).args(["-f", "avfoundation", "-list_devices", "true", "-i", ""]).stdin(Stdio::null()).output()?;
    let text = String::from_utf8_lossy(&o.stderr);
    let mut v: Vec<(u32, String)> = text
        .lines()
        .filter_map(|l| {
            let rest = l.rsplit_once("] [")?.1;
            let (idx, name) = rest.split_once("] ")?;
            let k = name.strip_prefix("Capture screen ")?.trim().parse().ok()?;
            Some((k, idx.to_string()))
        })
        .collect();
    v.sort();
    Ok(v.into_iter().map(|(_, i)| i).collect())
}

fn ff_cmd(ff: &Ffmpeg) -> std::process::Command {
    let mut c = std::process::Command::new(&ff.ffmpeg);
    c.arg("-hide_banner");
    c
}

/// One frame of the display as a ≤ 480 px PNG.
fn thumbnail(ff: &Ffmpeg, d: &Display) -> Option<Thumbnail> {
    let o = ff_cmd(ff)
        .args(["-loglevel", "error", "-f", "avfoundation", "-capture_cursor", "0", "-i"])
        .arg(format!("{}:none", d.avf))
        .args(["-frames:v", "1", "-vf", "scale=480:-2", "-f", "image2pipe", "-c:v", "png", "-"])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if o.stdout.len() < 24 {
        return None;
    }
    let w = u32::from_be_bytes(o.stdout[16..20].try_into().ok()?);
    let h = u32::from_be_bytes(o.stdout[20..24].try_into().ok()?);
    Some(Thumbnail { png: o.stdout, width: w, height: h })
}

impl Backend for MacBackend {
    fn name(&self) -> &'static str {
        "macos-dev"
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            system_picker: false,
            cursor: CursorSupport::Global,
            clicks: true,
            double_shift: true,
            notes: vec!["macos-dev records whole displays only (development build).".into()],
        }
    }

    fn list_sources(&self, thumbnails: bool) -> Result<Vec<Source>, CaptureError> {
        let ff = ffmpeg()?;
        Ok(displays(&ff)?
            .into_iter()
            .map(|d| Source {
                id: SourceId(format!("display:{}", d.id)),
                kind: SourceKind::Display,
                title: d.title.clone(),
                app: None,
                bounds: Rect { x: d.bounds.x * scale(&d), y: d.bounds.y * scale(&d), width: d.pixels.0 as f64, height: d.pixels.1 as f64 },
                scale: scale(&d),
                thumbnail: if thumbnails { thumbnail(&ff, &d) } else { None },
            })
            .collect())
    }

    fn pick(&self) -> Result<Option<Picked>, CaptureError> {
        Err(CaptureError::Unsupported("macos-dev has no system picker; use list_sources + choose".into()))
    }

    fn choose(&self, source: &SourceId) -> Result<Picked, CaptureError> {
        let ff = ffmpeg()?;
        let d = displays(&ff)?
            .into_iter()
            .find(|d| source.0 == format!("display:{}", d.id))
            .ok_or_else(|| CaptureError::Other("that display is gone".into()))?;
        Ok(Picked { kind: SourceKind::Display, size: d.pixels, inner: Box::new(d) })
    }

    fn start(&self, picked: Picked, opts: StartOptions, on_event: EventSink) -> Result<Recording, CaptureError> {
        let d = *picked.inner.downcast::<Display>().map_err(|_| CaptureError::Other("not a macos-dev source".into()))?;
        let ff = ffmpeg()?;
        let shared = session::prepare(&opts, SourceKind::Display, scale(&d), on_event)?;
        // The menu bar, which the hand goes up to when stopping from the Mac's own bar.
        *shared.bars.lock().unwrap() = vec![Bar::Top(40.0 / d.bounds.height.max(1.0))];
        session::start_camera(&shared, &opts);
        match MacCapture::start(&ff, &d, &opts, &shared) {
            Ok(c) => Ok(Recording::new(shared, Box::new(c))),
            Err(e) => {
                session::discard(&shared);
                Err(e)
            }
        }
    }
}

fn scale(d: &Display) -> f64 {
    d.pixels.0 as f64 / d.bounds.width.max(1.0)
}

struct MacCapture {
    child: Child,
    stdin: Option<ChildStdin>,
    file: PathBuf,
    pixels: (u32, u32),
    stop: Arc<AtomicBool>,
    pointer: Option<JoinHandle<()>>,
    progress: Option<JoinHandle<f64>>,
}

impl MacCapture {
    fn start(ff: &Ffmpeg, d: &Display, opts: &StartOptions, shared: &Arc<Shared>) -> Result<MacCapture, CaptureError> {
        let file = shared.folder.join("screen.mp4");
        let enc = ff.best_encoder();
        let fps = opts.fps.to_string();
        // Not ff.command(): that adds -nostdin, and a clean stop is 'q' on stdin.
        let mut cmd = std::process::Command::new(&ff.ffmpeg);
        cmd.args(["-hide_banner", "-loglevel", "error", "-y", "-progress", "pipe:1", "-stats_period", "0.05"])
            .args(["-f", "avfoundation", "-capture_cursor", "0", "-capture_mouse_clicks", "0", "-framerate", &fps, "-i"])
            .arg(format!("{}:none", d.avf))
            .args(["-fps_mode", "cfr", "-r", &fps])
            .args(enc.args(opts.fps))
            .args(["-movflags", "+faststart", "-an"])
            .arg(&file)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = cmd.spawn().map_err(|e| CaptureError::Ffmpeg(format!("could not start ffmpeg: {e}")))?;
        let stdin = child.stdin.take();
        let stdout = child.stdout.take().expect("stdout");
        let stderr = child.stderr.take().expect("stderr");
        let errors = Arc::new(Mutex::new(String::new()));
        let e2 = errors.clone();
        std::thread::spawn(move || {
            for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                log::error!("ffmpeg: {line}");
                let mut e = e2.lock().unwrap();
                e.push_str(&line);
                e.push('\n');
            }
        });

        // Time zero from ffmpeg's progress: a report at instant R saying the
        // file reached T puts frame 0 at no later than R − T; the smallest
        // such value over the first second is the least delayed estimate.
        let (first_tx, first_rx) = mpsc::channel::<()>();
        let sh = shared.clone();
        let progress = std::thread::Builder::new()
            .name("monetshot-progress".into())
            .spawn(move || {
                let mut best: Option<Instant> = None;
                let mut since: Option<Instant> = None;
                let mut marked = false;
                let mut last_t = 0.0;
                let mut first_tx = Some(first_tx);
                for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                    let Some(us) = line.strip_prefix("out_time_us=").and_then(|v| v.trim().parse::<i64>().ok()) else { continue };
                    if us <= 0 {
                        continue;
                    }
                    let now = Instant::now();
                    let t = us as f64 / 1e6;
                    last_t = t;
                    let est = now.checked_sub(Duration::from_secs_f64(t)).unwrap_or(now);
                    best = Some(best.map_or(est, |b| b.min(est)));
                    if let Some(tx) = first_tx.take() {
                        since = Some(now);
                        let _ = tx.send(());
                    }
                    if !marked && since.is_some_and(|s| now - s > Duration::from_millis(600)) {
                        marked = true;
                        sh.first_frame(best.unwrap());
                    }
                }
                if !marked {
                    if let Some(b) = best {
                        sh.first_frame(b);
                    }
                }
                last_t
            })
            .map_err(|e| CaptureError::Other(e.to_string()))?;

        // Wait for frames (or ffmpeg giving up: no permission, no display).
        if first_rx.recv_timeout(Duration::from_secs(10)).is_err() {
            let _ = child.kill();
            let _ = child.wait();
            let _ = progress.join();
            let detail = errors.lock().unwrap().trim().to_string();
            let hint = "allow Screen Recording for the app running this in System Settings › Privacy & Security";
            return Err(CaptureError::Ffmpeg(if detail.is_empty() { format!("no frames from the screen ({hint})") } else { format!("{detail} ({hint})") }));
        }
        log::info!(
            "capture started: display {}x{} @{:.0}x via {} -> {}",
            d.pixels.0,
            d.pixels.1,
            scale(d),
            enc.name(),
            shared.folder.display()
        );

        let stop = Arc::new(AtomicBool::new(false));
        let pointer = spawn_pointer(shared.clone(), d.bounds, stop.clone());
        Ok(MacCapture { child, stdin, file, pixels: d.pixels, stop, pointer: Some(pointer), progress: Some(progress) })
    }

    fn end(&mut self) -> Result<(), CaptureError> {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(p) = self.pointer.take() {
            let _ = p.join();
        }
        if let Some(mut s) = self.stdin.take() {
            let _ = s.write_all(b"q");
        }
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            match self.child.try_wait()? {
                Some(st) if st.success() || st.code() == Some(255) => return Ok(()),
                Some(st) => return Err(CaptureError::Ffmpeg(format!("ffmpeg ended with {st}"))),
                None if Instant::now() > deadline => {
                    let _ = self.child.kill();
                    let _ = self.child.wait();
                    return Err(CaptureError::Ffmpeg("ffmpeg didn't finish the file".into()));
                }
                None => std::thread::sleep(Duration::from_millis(20)),
            }
        }
    }
}

impl Capture for MacCapture {
    fn finish(mut self: Box<Self>) -> Result<Video, CaptureError> {
        self.end()?;
        let duration = self.progress.take().and_then(|p| p.join().ok()).unwrap_or(0.0);
        Ok(Video { file: self.file.clone(), width: self.pixels.0, height: self.pixels.1, duration })
    }

    fn abort(mut self: Box<Self>) {
        let _ = self.end();
        if let Some(p) = self.progress.take() {
            let _ = p.join();
        }
    }
}

// CoreGraphics' input state, which the core-graphics crate doesn't wrap.
#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGEventSourceButtonState(state: i32, button: u32) -> bool;
    fn CGEventSourceFlagsState(state: i32) -> u64;
}

const COMBINED_SESSION: i32 = 0;
const SHIFT: u64 = 0x0002_0000;
const OTHERS: u64 = 0x0004_0000 | 0x0008_0000 | 0x0010_0000; // control, option, command

/// The pointer (points, global, top-left origin), now.
fn pointer_location() -> Option<(f64, f64)> {
    use core_graphics::event::CGEvent;
    use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
    let src = CGEventSource::new(CGEventSourceStateID::CombinedSessionState).ok()?;
    let p = CGEvent::new(src).ok()?.location();
    Some((p.x, p.y))
}

fn spawn_pointer(shared: Arc<Shared>, bounds: Rect, stop: Arc<AtomicBool>) -> JoinHandle<()> {
    std::thread::Builder::new()
        .name("monetshot-pointer".into())
        .spawn(move || {
            let period = Duration::from_secs_f64(1.0 / 120.0);
            let mut next = Instant::now();
            let mut down = [false; 2];
            while !stop.load(Ordering::SeqCst) {
                let Some((px, py)) = pointer_location() else { continue };
                let (x, y) = bounds.normalise(px, py);
                shared.position(x, y);
                for (b, was) in down.iter_mut().enumerate() {
                    let now = unsafe { CGEventSourceButtonState(COMBINED_SESSION, b as u32) };
                    if now && !*was {
                        shared.click(x, y);
                    }
                    *was = now;
                }
                let flags = unsafe { CGEventSourceFlagsState(COMBINED_SESSION) };
                shared.modifiers(flags & SHIFT != 0, flags & OTHERS != 0);
                next += period;
                let now = Instant::now();
                if next > now {
                    std::thread::sleep(next - now);
                } else {
                    next = now;
                }
            }
        })
        .expect("pointer thread")
}
