//! What every backend shares while recording: the pointer log, pauses,
//! the clock, ticks, the camera alongside, and finishing into a take
//! folder. A backend supplies frames and pointer input; this does the rest,
//! the way `ScreenRecorder` + `CursorTracker` do on the Mac.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::camera::CameraHold;
use crate::pointer::{Bar, CursorLog, DoubleShift, Key};
use crate::{take, CaptureError, Event, EventSink, SourceKind, StartOptions};

/// The video side of a recording, owned by the backend.
pub(crate) trait Capture: Send {
    /// Stops frames and pointer input and closes the file.
    fn finish(self: Box<Self>) -> Result<Video, CaptureError>;
    /// Stops everything; the folder is removed by the session.
    fn abort(self: Box<Self>);
}

/// The finished video file.
pub(crate) struct Video {
    pub file: PathBuf,
    pub width: u32,
    pub height: u32,
    /// The writer's own count; replaced by ffprobe's when it can read the file.
    pub duration: f64,
}

#[derive(Default)]
struct Clock {
    t0: Option<Instant>,
    pauses: Vec<(f64, f64)>,
    paused_at: Option<f64>,
    ended: bool,
}

/// Shared by the backend's threads (pointer, keys, frames) and the handle.
pub(crate) struct Shared {
    log: Mutex<CursorLog>,
    shift: Mutex<DoubleShift>,
    clock: Mutex<Clock>,
    on_event: EventSink,
    pub folder: PathBuf,
    /// The project a new take belongs to.
    pub take_into: Option<PathBuf>,
    pub kind: SourceKind,
    pub scale: f64,
    /// The bars the user stops from (tray's bar, the pill), as fractions of the content.
    pub bars: Mutex<Vec<Bar>>,
    camera: Mutex<Option<(CameraHold, Instant)>>,
    created: Instant,
}

impl Shared {
    pub fn emit(&self, e: Event) {
        (self.on_event)(e)
    }

    /// The pointer at the content-normalised position `(x, y)`, now.
    pub fn position(&self, x: f64, y: f64) {
        self.log.lock().unwrap().sample(Instant::now(), x, y);
    }

    pub fn click(&self, x: f64, y: f64) {
        self.click_at(Instant::now(), x, y);
    }

    // Used by the Linux and Windows backends.
    #[cfg_attr(target_os = "macos", allow(dead_code))]
    /// A click seen at `at` where the pointer last was (evdev knows the
    /// button, not where the pointer is). Nothing without a pointer log.
    pub fn click_here(&self, at: Instant) {
        let mut l = self.log.lock().unwrap();
        if let Some(p) = l.samples.last().copied() {
            l.click(at, p.x, p.y);
        }
    }

    /// A click seen at `at` (hooks queue them; the moment is the hook's).
    pub fn click_at(&self, at: Instant, x: f64, y: f64) {
        self.log.lock().unwrap().click(at, x, y);
    }

    /// The modifier state, from a poll (the Mac's way, and macos-dev's).
    pub fn modifiers(self: &Arc<Self>, shift: bool, others: bool) {
        let t = self.created.elapsed().as_secs_f64();
        if self.shift.lock().unwrap().poll(t, shift, others) {
            self.toggle_pause();
        }
    }

    #[cfg_attr(target_os = "macos", allow(dead_code))]
    /// A key event, from a hook (Windows, evdev, X11).
    pub fn key(self: &Arc<Self>, key: Key, down: bool) {
        let t = self.created.elapsed().as_secs_f64();
        if self.shift.lock().unwrap().key(t, key, down) {
            self.toggle_pause();
        }
    }

    pub fn ended(&self) -> bool {
        self.clock.lock().unwrap().ended
    }

    /// Time zero: the first frame was written at `at`.
    pub fn first_frame(self: &Arc<Self>, at: Instant) {
        {
            let mut c = self.clock.lock().unwrap();
            if c.t0.is_some() || c.ended {
                return;
            }
            c.t0 = Some(at);
        }
        self.log.lock().unwrap().mark_start(at);
        log::info!("recording started -> {}", self.folder.display());
        self.emit(Event::Started);
        let me = Arc::clone(self);
        std::thread::Builder::new()
            .name("monetshot-tick".into())
            .spawn(move || {
                while !me.ended() {
                    std::thread::sleep(Duration::from_millis(250));
                    if me.ended() {
                        break;
                    }
                    let (elapsed, paused) = me.elapsed();
                    me.emit(Event::Tick { elapsed, paused });
                }
            })
            .ok();
    }

    /// Recording time now (seconds since the first frame; 0 before it).
    fn now(&self, c: &Clock) -> f64 {
        c.t0.map(|t| t.elapsed().as_secs_f64()).unwrap_or(0.0)
    }

    /// Recorded seconds, pauses not counted, and whether paused now.
    pub fn elapsed(&self) -> (f64, bool) {
        let c = self.clock.lock().unwrap();
        let now = self.now(&c);
        let paused: f64 = c.pauses.iter().map(|(a, b)| b - a).sum::<f64>() + c.paused_at.map(|p| now - p).unwrap_or(0.0);
        ((now - paused).max(0.0), c.paused_at.is_some())
    }

    /// Pausing keeps capturing and marks the stretch, which becomes a cut.
    pub fn toggle_pause(&self) {
        let on = {
            let mut c = self.clock.lock().unwrap();
            if c.t0.is_none() || c.ended {
                return;
            }
            let t = self.now(&c);
            if let Some(start) = c.paused_at.take() {
                if t - start > 0.05 {
                    c.pauses.push((start, t));
                }
                log::info!("resumed at {t:.1}s");
                false
            } else {
                c.paused_at = Some(t);
                log::info!("paused at {t:.1}s");
                true
            }
        };
        self.emit(Event::Paused(on));
    }

    fn end(&self) -> (Option<Instant>, Vec<(f64, f64)>, Option<f64>) {
        let mut c = self.clock.lock().unwrap();
        c.ended = true;
        (c.t0, std::mem::take(&mut c.pauses), c.paused_at.take())
    }

    fn take_log(&self) -> (Vec<crate::pointer::Sample>, Vec<crate::pointer::Sample>) {
        let mut l = self.log.lock().unwrap();
        (std::mem::take(&mut l.samples), std::mem::take(&mut l.clicks))
    }
}

/// Makes the folder for a new recording (or the next take) and the shared
/// state. Starts the camera file too when the recording wants it.
pub(crate) fn prepare(opts: &StartOptions, kind: SourceKind, scale: f64, on_event: EventSink) -> Result<Arc<Shared>, CaptureError> {
    let (folder, take_into) = take::folder_for(opts)?;
    std::fs::create_dir_all(&folder)?;
    Ok(Arc::new(Shared {
        log: Mutex::new(CursorLog::new(Instant::now())),
        shift: Mutex::new(DoubleShift::default()),
        clock: Mutex::new(Clock::default()),
        on_event,
        folder,
        take_into,
        kind,
        scale,
        bars: Mutex::new(Vec::new()),
        camera: Mutex::new(None),
        created: Instant::now(),
    }))
}

/// "Record my camera too": starts `camera.mp4` in the take folder, before
/// the screen (as the Mac does). A camera that fails is a warning, not a
/// failed recording.
pub(crate) fn start_camera(shared: &Arc<Shared>, opts: &StartOptions) {
    let Some(choice) = &opts.camera else { return };
    let hold = match crate::camera::Camera::acquire(choice, None) {
        Ok(h) => h,
        Err(e) => {
            log::error!("camera with the screen: {e}");
            shared.emit(Event::Warning(format!("The camera didn't start: {e}")));
            return;
        }
    };
    match hold.record(&shared.folder.join("camera.mp4")) {
        Ok(at) => *shared.camera.lock().unwrap() = Some((hold, at)),
        Err(e) => {
            log::error!("camera with the screen: {e}");
            shared.emit(Event::Warning(format!("The camera didn't record: {e}")));
        }
    }
}

/// Undoes `prepare` + `start_camera` when the backend couldn't start.
pub(crate) fn discard(shared: &Shared) {
    shared.end();
    stop_camera(shared);
    remove(shared);
}

/// The handle the app holds while recording.
pub struct Recording {
    shared: Arc<Shared>,
    capture: Mutex<Option<Box<dyn Capture>>>,
}

impl Recording {
    pub(crate) fn new(shared: Arc<Shared>, capture: Box<dyn Capture>) -> Recording {
        Recording { shared, capture: Mutex::new(Some(capture)) }
    }

    /// Pause or resume (double-tap Shift does the same).
    pub fn toggle_pause(&self) {
        self.shared.toggle_pause()
    }

    pub fn is_paused(&self) -> bool {
        self.shared.elapsed().1
    }

    /// Recorded seconds, pauses not counted.
    pub fn elapsed(&self) -> f64 {
        self.shared.elapsed().0
    }

    pub fn folder(&self) -> &Path {
        &self.shared.folder
    }

    /// Stops; `Finished`, `FinishedTake` or `Failed` follows from another thread.
    pub fn stop(&self) {
        let Some(capture) = self.capture.lock().unwrap().take() else { return };
        log::info!("stop requested");
        let shared = Arc::clone(&self.shared);
        std::thread::Builder::new()
            .name("monetshot-finish".into())
            .spawn(move || finish(shared, capture))
            .ok();
    }

    /// Stops and throws the recording away (the app is quitting).
    pub fn abort(&self) {
        let Some(capture) = self.capture.lock().unwrap().take() else { return };
        self.shared.end();
        capture.abort();
        stop_camera(&self.shared);
        remove(&self.shared);
        log::info!("recording aborted");
    }
}

impl Drop for Recording {
    fn drop(&mut self) {
        self.abort();
    }
}

fn stop_camera(shared: &Shared) -> Option<(PathBuf, Instant)> {
    let (hold, at) = shared.camera.lock().unwrap().take()?;
    match hold.stop() {
        Ok(Some(file)) => Some((file, at)),
        Ok(None) => None,
        Err(e) => {
            log::error!("camera: {e}");
            None
        }
    }
}

/// Removes what a failed or aborted recording left: the whole folder.
fn remove(shared: &Shared) {
    let _ = std::fs::remove_dir_all(&shared.folder);
}

fn finish(shared: Arc<Shared>, capture: Box<dyn Capture>) {
    let video = capture.finish();
    let (t0, pauses, open_pause) = shared.end();
    let camera = stop_camera(&shared);
    let fail = |msg: String| {
        log::error!("{msg}");
        remove(&shared);
        shared.emit(Event::Failed(msg));
    };
    let video = match video {
        Ok(v) => v,
        Err(e) => return fail(format!("recording failed: {e}")),
    };
    let Some(t0) = t0 else { return fail("recording failed: no frame was written".into()) };
    let (samples, clicks) = shared.take_log();
    let duration = crate::ffmpeg::ffmpeg().ok().and_then(|f| f.duration(&video.file)).unwrap_or(video.duration);
    let input = take::TakeInput {
        folder: &shared.folder,
        take_into: shared.take_into.as_deref(),
        video: &video,
        duration,
        kind: shared.kind,
        scale: shared.scale,
        samples,
        clicks,
        pauses,
        open_pause,
        bars: shared.bars.lock().unwrap().clone(),
        camera: camera.map(|(file, at)| {
            let offset = at.saturating_duration_since(t0).as_secs_f64() - t0.saturating_duration_since(at).as_secs_f64();
            (file, offset)
        }),
    };
    match take::write(input) {
        Ok(e) => shared.emit(e),
        Err(e) => fail(format!("could not save the recording: {e}")),
    }
}
