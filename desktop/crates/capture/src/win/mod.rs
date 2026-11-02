//! Windows: Windows.Graphics.Capture for frames (system cursor off, yellow
//! border off where Windows allows), our own picker fed by `list_sources`,
//! the pointer from GetCursorPos at 120 Hz, clicks and double-tap Shift from
//! low-level hooks, and ffmpeg (the bundled sidecar) encoding from stdin.
//! Everything is in physical pixels: the process is per-monitor DPI aware v2.

mod input;
mod sources;
mod wgc;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use ::windows::Win32::Foundation::HWND;
use ::windows::Win32::Graphics::Gdi::HMONITOR;
use ::windows::Win32::UI::HiDpi::{SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};

use crate::ffmpeg::ffmpeg;
use crate::pipe::{Pipe, PixelFormat};
use crate::session::{self, Capture, Video};
use crate::{
    Backend, Capabilities, CaptureError, CursorSupport, EventSink, Picked, Recording, Rect, Source, SourceId, SourceKind,
    StartOptions,
};

pub struct WindowsBackend;

impl WindowsBackend {
    pub fn new() -> Self {
        // Tauri's manifest usually does this already; harmless if so.
        unsafe {
            let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        }
        WindowsBackend
    }
}

impl Default for WindowsBackend {
    fn default() -> Self {
        Self::new()
    }
}

/// What was chosen: a monitor or a window, with what we knew at the time.
#[derive(Clone, Copy, Debug)]
pub(crate) enum Target {
    Monitor { handle: isize, bounds: Rect, work: Rect, scale: f64 },
    Window { hwnd: isize, bounds: Rect, scale: f64 },
}

impl Target {
    fn bounds(&self) -> Rect {
        match *self {
            Target::Monitor { bounds, .. } | Target::Window { bounds, .. } => bounds,
        }
    }
    fn scale(&self) -> f64 {
        match *self {
            Target::Monitor { scale, .. } | Target::Window { scale, .. } => scale,
        }
    }
    pub(crate) fn hwnd(&self) -> Option<HWND> {
        match *self {
            Target::Window { hwnd, .. } => Some(HWND(hwnd as *mut _)),
            _ => None,
        }
    }
    pub(crate) fn hmonitor(&self) -> Option<HMONITOR> {
        match *self {
            Target::Monitor { handle, .. } => Some(HMONITOR(handle as *mut _)),
            _ => None,
        }
    }
}

impl Backend for WindowsBackend {
    fn name(&self) -> &'static str {
        "windows"
    }

    fn capabilities(&self) -> Capabilities {
        let mut notes = Vec::new();
        if !wgc::supported() {
            notes.push("Screen capture needs Windows 10 version 1903 or later.".into());
        }
        Capabilities { system_picker: false, cursor: CursorSupport::Global, clicks: true, double_shift: true, notes }
    }

    fn list_sources(&self, thumbnails: bool) -> Result<Vec<Source>, CaptureError> {
        sources::list(thumbnails)
    }

    fn pick(&self) -> Result<Option<Picked>, CaptureError> {
        Err(CaptureError::Unsupported("Windows uses Monet Shot's own picker: list_sources + choose".into()))
    }

    fn choose(&self, source: &SourceId) -> Result<Picked, CaptureError> {
        let t = sources::resolve(source)?;
        let b = t.bounds();
        let kind = if matches!(t, Target::Monitor { .. }) { SourceKind::Display } else { SourceKind::Window };
        Ok(Picked { kind, size: (b.width as u32, b.height as u32), inner: Box::new(t) })
    }

    fn start(&self, picked: Picked, opts: StartOptions, on_event: EventSink) -> Result<Recording, CaptureError> {
        let kind = picked.kind;
        let target = *picked.inner.downcast::<Target>().map_err(|_| CaptureError::Other("not a Windows source".into()))?;
        let ff = ffmpeg()?;
        let shared = session::prepare(&opts, kind, target.scale(), on_event)?;
        if let Target::Monitor { bounds, work, .. } = target {
            *shared.bars.lock().unwrap() = sources::stop_bars(bounds, work, target.scale());
        }
        session::start_camera(&shared, &opts);
        let result = (|| -> Result<WinCapture, CaptureError> {
            let frames = wgc::Frames::open(&target)?;
            let size = frames.size();
            let sh = shared.clone();
            let pipe = Pipe::start(&ff, ff.best_encoder(), &shared.folder.join("screen.mp4"), size, PixelFormat::Bgra, opts.fps, move |t0| {
                sh.first_frame(t0)
            })?;
            let frames = frames.start(pipe.slot())?;
            let stop = Arc::new(AtomicBool::new(false));
            let input = input::Input::start(shared.clone(), target, size, stop.clone())?;
            log::info!(
                "capture started: {} {}x{} @{:.2}x via {} -> {}",
                kind.meta(),
                size.0,
                size.1,
                target.scale(),
                ff.best_encoder().name(),
                shared.folder.display()
            );
            Ok(WinCapture { frames: Some(frames), pipe: Some(pipe), input: Some(input), stop, size })
        })();
        match result {
            Ok(c) => Ok(Recording::new(shared, Box::new(c))),
            Err(e) => {
                session::discard(&shared);
                Err(e)
            }
        }
    }
}

struct WinCapture {
    frames: Option<wgc::Running>,
    pipe: Option<Pipe>,
    input: Option<input::Input>,
    stop: Arc<AtomicBool>,
    size: (u32, u32),
}

impl WinCapture {
    fn halt(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(i) = self.input.take() {
            i.stop();
        }
        if let Some(f) = self.frames.take() {
            f.stop();
        }
    }
}

impl Capture for WinCapture {
    fn finish(mut self: Box<Self>) -> Result<Video, CaptureError> {
        self.halt();
        let r = self.pipe.take().expect("pipe").finish()?;
        let (w, h) = crate::pipe::even(self.size.0, self.size.1);
        Ok(Video { file: r.file, width: w, height: h, duration: r.duration })
    }

    fn abort(mut self: Box<Self>) {
        self.halt();
        if let Some(p) = self.pipe.take() {
            let _ = p.finish();
        }
    }
}
