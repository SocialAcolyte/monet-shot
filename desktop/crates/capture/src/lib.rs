//! Screen, pointer, camera and microphone capture for Monet Shot on Linux
//! (incl. Omarchy), Windows, and macOS for development.
//!
//! The contract is `docs/porting/contracts/capture.md`. A recording ends as
//! a take folder exactly like the Mac's (`Sources/MonetShot/Recording`).

use std::path::PathBuf;
use std::sync::Arc;

pub mod camera;
pub mod voice;
pub mod ffmpeg;
pub mod pipe;
pub mod pointer;
pub mod status;

mod session;
mod take;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "macos")]
mod macos;
#[cfg(windows)]
mod win;

pub use camera::{cameras, microphones, Camera, CameraChoice, CameraHold, Device, PreviewSink};
pub use ffmpeg::{ffmpeg, Ffmpeg};
pub use session::Recording;

#[derive(Debug, thiserror::Error)]
pub enum CaptureError {
    #[error("{0}")]
    Ffmpeg(String),
    #[error("{0}")]
    Unsupported(String),
    #[error("{0}")]
    Denied(String),
    #[error("{0}")]
    Io(#[from] std::io::Error),
    #[error("{0}")]
    Other(String),
}

/// The backend for this OS and session.
pub fn backend() -> Box<dyn Backend> {
    #[cfg(windows)]
    return Box::new(win::WindowsBackend::new());
    #[cfg(target_os = "linux")]
    return Box::new(linux::LinuxBackend::new());
    #[cfg(target_os = "macos")]
    return Box::new(macos::MacBackend::new());
    #[allow(unreachable_code)]
    {
        unimplemented!("no capture backend for this OS")
    }
}

pub trait Backend: Send + Sync {
    /// "windows", "linux-portal" or "macos-dev".
    fn name(&self) -> &'static str;
    fn capabilities(&self) -> Capabilities;
    /// Displays and windows for our own picker. Empty where the system
    /// picker is the only way in (the portal).
    fn list_sources(&self, thumbnails: bool) -> Result<Vec<Source>, CaptureError>;
    /// The system picker, where there is one. Ok(None) = cancelled.
    fn pick(&self) -> Result<Option<Picked>, CaptureError>;
    /// A source from our own picker.
    fn choose(&self, source: &SourceId) -> Result<Picked, CaptureError>;
    /// Starts recording. Returns once capture runs; `Event::Started`
    /// follows with the first frame. On error nothing is left on disk.
    fn start(&self, picked: Picked, opts: StartOptions, on_event: EventSink) -> Result<Recording, CaptureError>;
    /// Forget the remembered system-picker choice, so the next `pick` asks
    /// again ("Choose what to record…"). No-op where nothing is remembered.
    fn forget_pick(&self) {}
}

pub type EventSink = Arc<dyn Fn(Event) + Send + Sync>;

#[derive(Clone, Debug)]
pub struct Capabilities {
    pub system_picker: bool,
    pub cursor: CursorSupport,
    pub clicks: bool,
    pub double_shift: bool,
    /// Plain sentences for the UI, e.g. why clicks aren't logged.
    pub notes: Vec<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CursorSupport {
    /// A global pointer position (Windows, Hyprland, X11, macOS).
    Global,
    /// Only while over the captured content (PipeWire cursor metadata).
    StreamMetadata,
    None,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct SourceId(pub String);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SourceKind {
    Display,
    Window,
}

impl SourceKind {
    /// `meta.source`.
    pub fn meta(self) -> &'static str {
        match self {
            SourceKind::Display => "display",
            SourceKind::Window => "window",
        }
    }
}

/// Physical pixels in virtual-desktop coordinates, origin top-left.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    /// `p` as a fraction of this rectangle (outside gives < 0 or > 1).
    pub fn normalise(&self, px: f64, py: f64) -> (f64, f64) {
        ((px - self.x) / self.width.max(1.0), (py - self.y) / self.height.max(1.0))
    }
}

#[derive(Clone, Debug)]
pub struct Source {
    pub id: SourceId,
    pub kind: SourceKind,
    pub title: String,
    pub app: Option<String>,
    pub bounds: Rect,
    pub scale: f64,
    pub thumbnail: Option<Thumbnail>,
}

#[derive(Clone, Debug)]
pub struct Thumbnail {
    pub png: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

/// The chosen content, held through the 3-2-1.
pub struct Picked {
    pub(crate) kind: SourceKind,
    pub(crate) size: (u32, u32),
    pub(crate) inner: Box<dyn std::any::Any + Send>,
}

impl Picked {
    pub fn kind(&self) -> SourceKind {
        self.kind
    }
    /// Pixel size of the content as it will be recorded.
    pub fn size(&self) -> (u32, u32) {
        self.size
    }
}

impl std::fmt::Debug for Picked {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Picked").field("kind", &self.kind).field("size", &self.size).finish()
    }
}

#[derive(Clone, Debug)]
pub struct StartOptions {
    /// Where new recordings go (core's library dir).
    pub library: PathBuf,
    /// Record a new take of this project instead of a new recording.
    pub take_into: Option<PathBuf>,
    /// "Record my camera too".
    pub camera: Option<CameraChoice>,
    /// Your voice from this microphone ("default" = the system's) when the
    /// camera isn't recording; None = no voice.
    pub mic: Option<String>,
    pub fps: u32,
}

impl StartOptions {
    pub fn new(library: impl Into<PathBuf>) -> Self {
        StartOptions { library: library.into(), take_into: None, camera: None, mic: None, fps: 60 }
    }
}

#[derive(Clone, Debug)]
pub enum Event {
    /// The first frame is written; the clock starts.
    Started,
    /// 4 times a second while recording.
    Tick { elapsed: f64, paused: bool },
    Paused(bool),
    /// Recording goes on, but something is missing (camera, cursor, clicks).
    Warning(String),
    /// A new recording, ready for the editor.
    Finished { folder: PathBuf },
    /// A new take of `project`, with the clips it brings (pauses left out).
    FinishedTake { project: PathBuf, take: PathBuf, clips: Vec<monetshot_core::Clip> },
    /// Nothing was kept; show "Couldn't record".
    Failed(String),
}

/// RGBA pixels as PNG bytes (thumbnails).
#[allow(dead_code)]
pub(crate) fn png_rgba(rgba: &[u8], width: u32, height: u32) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let mut e = png::Encoder::new(&mut out, width, height);
    e.set_color(png::ColorType::Rgba);
    e.set_depth(png::BitDepth::Eight);
    let mut w = e.write_header().ok()?;
    w.write_image_data(rgba).ok()?;
    w.finish().ok()?;
    Some(out)
}
