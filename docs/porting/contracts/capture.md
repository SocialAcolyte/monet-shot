# Capture contract

Owner: **ms-capture**. Crate: `desktop/crates/capture`, package
`monetshot-capture`, lib `monetshot_capture`. Readers: ms-app (calls it),
ms-core (its types are what we write).

Reference behaviour: `Sources/MonetShot/Recording/*` and
`Sources/MonetShot/UI/MenuBarModel.swift`. Where this says "as the Mac", the
Swift is the spec.

## What a recording produces

A take folder exactly as the Mac writes one, so it opens on the Mac too:

```
<library>/2026-11-01 14.02.11.reel/      (or <project>/take-N/ for a new take)
  screen.mp4     H.264 (yuv420p, even size), no audio, the system cursor NOT drawn
  cursor.json    CursorTrack: samples (≈120 Hz, still pointer ≤ 1 per 0.5 s) + clicks
  meta.json      RecordingMeta, with "video": "screen.mp4"
  edit.json      first take only: cuts (from pauses), auto-zoom segments, trimEnd
  camera.mp4     optional, "Record my camera too": H.264 + AAC (mic), meta.camera/cameraOffset
```

- `t = 0` is the first frame of `screen.mp4`. Samples logged before it are
  re-timed and dropped as the Mac's `CursorTracker.markStart` does (samples
  `t >= -0.05`, clicks `t >= 0`).
- Positions are normalised to the **captured content**: (0,0) top-left of the
  video frame, (1,1) bottom-right. Pointer outside the content gives values
  outside 0..1 (kept, as the Mac does).
- `meta`: `pixelWidth/Height` = the video's size; `pointScale` = the content's
  scale factor (Windows DPI / 96, Hyprland monitor scale, 1 when unknown);
  `duration` = the file's real duration (ffprobe), else the last frame time;
  `source` = `"display"` or `"window"`; `createdAt` whole seconds.
- The video is **constant frame rate** (60 fps default): the encoder clock
  repeats the last frame when the screen is still (Windows.Graphics.Capture
  and PipeWire only deliver changes), so file time == wall time and the
  cursor log lines up without a PTS map.
- **Pauses** keep capturing (as the Mac) and become `edit.cuts`, sorted,
  each `> 0.05 s`; a pause still open at stop runs to the end.
- `edit.segments = autoZooms(clicks kept by the TimeMap, duration)` and the
  "hand went to the bar to stop" trim (`trimEnd`), both via `monetshot-core`,
  exactly as `ScreenRecorder.finish()`. The trim uses the bar the user stops
  from: Omarchy/most Linux = the top reserved band (Hyprland monitor
  `reserved`), Windows = the taskbar edge (`rcMonitor` − `rcWork`).
- A new take (`take_into`) writes `meta.json` + `cursor.json` only (no
  edit.json) into `next_take_folder()` and reports its clips.

JSON writing goes through `monetshot-core` (sorted keys, pretty, whole-second
ISO dates), never hand-rolled here.

## Rust API

Blocking calls; run them off the UI thread (`spawn_blocking`). Events come
through a callback that may be called from any thread.

```rust
pub fn backend() -> Box<dyn Backend>;           // the one for this OS/session
pub fn ffmpeg() -> Result<Ffmpeg, CaptureError>; // located binary + encoders (sidecar on Windows)

pub trait Backend: Send + Sync {
    fn name(&self) -> &'static str;              // "windows" | "linux-portal" | "macos-dev"
    fn capabilities(&self) -> Capabilities;
    /// Displays and windows for our own picker (Windows, macos-dev).
    /// Empty on the portal backend: the system picker is the only way in.
    fn list_sources(&self, thumbnails: bool) -> Result<Vec<Source>, CaptureError>;
    /// The system picker where one exists (Linux portal). Ok(None) = cancelled.
    /// Remembers the portal restore token, so the next pick of the same
    /// content skips the dialog (MONETSHOT state dir, `portal-token`).
    fn pick(&self) -> Result<Option<Picked>, CaptureError>;
    /// Our picker's choice -> Picked (Windows, macos-dev).
    fn choose(&self, source: &SourceId) -> Result<Picked, CaptureError>;
    /// Starts recording. Returns once capture is running; `Event::Started`
    /// follows when the first frame is written. On error the folder is removed.
    fn start(&self, picked: Picked, opts: StartOptions, on_event: EventSink)
        -> Result<Recording, CaptureError>;
    /// Forget the portal's remembered choice: "Choose what to record…".
    fn forget_pick(&self) {}
}

pub type EventSink = Arc<dyn Fn(Event) + Send + Sync>;

pub struct Capabilities {
    pub system_picker: bool,          // true: call pick(); false: list_sources() + choose()
    pub cursor: CursorSupport,        // Global | StreamMetadata | None
    pub clicks: bool,                 // false e.g. Linux without the `input` group
    pub double_shift: bool,
    pub notes: Vec<String>,           // plain sentences for the UI ("Clicks need …")
}

pub struct Source {
    pub id: SourceId,                 // opaque, stable while the thing exists
    pub kind: SourceKind,             // Display | Window
    pub title: String,                // "Display 1 (2560×1440)" / window title
    pub app: Option<String>,          // owning app for windows
    pub bounds: Rect,                 // physical pixels, virtual-desktop coords
    pub scale: f64,
    pub thumbnail: Option<Thumbnail>, // PNG bytes, ≤ 480 px wide
}

pub struct Picked { /* opaque: the chosen content, held through the 3-2-1 */ }
impl Picked { pub fn kind(&self) -> SourceKind; pub fn size(&self) -> (u32, u32); }

pub struct StartOptions {
    pub library: PathBuf,             // core::paths::library_dir()
    pub take_into: Option<PathBuf>,   // record a new take of this project
    pub camera: Option<CameraChoice>, // "Record my camera too" (see Camera)
    pub fps: u32,                     // 60
}

pub struct Recording { .. }
impl Recording {
    pub fn toggle_pause(&self);       // also fired by double-tap Shift
    pub fn is_paused(&self) -> bool;
    pub fn elapsed(&self) -> f64;     // recorded seconds, pauses not counted
    pub fn stop(&self);               // -> Event::Finished / FinishedTake / Failed
    pub fn abort(&self);              // stop and delete the folder (app quitting)
    pub fn folder(&self) -> &Path;
}

pub enum Event {
    Started,                          // first frame written; the clock starts
    Tick { elapsed: f64, paused: bool },   // 4 Hz while recording
    Paused(bool),
    Warning(String),                  // recording continues ("camera didn't start", "no cursor")
    Finished { folder: PathBuf },     // new project -> open the editor
    FinishedTake { project: PathBuf, take: PathBuf, clips: Vec<core::Clip> },
    Failed(String),                   // folder removed; app shows "Couldn't record"
}
```

App state machine stays the Mac's (`MenuBarModel`): idle → pick/choose
(cancel → idle) → 3-2-1 in the app → `start` → `Started` → recording →
hold to stop → `stop()` → `Finished` → editor. `Failed` at any point → idle,
"Couldn't record" for 4 s, details in the log.

## Camera + microphone

One shared camera, as the Mac's `CameraRecorder.shared`: the live preview and
the recorded file come from the same capture (cameras are exclusive on v4l2
and most Windows drivers, so the webview must NOT open the camera itself).

```rust
pub fn cameras() -> Result<Vec<Device>, CaptureError>;      // v4l2 / dshow / avfoundation
pub fn microphones() -> Result<Vec<Device>, CaptureError>;  // pulse(pipewire) / dshow / avfoundation
pub struct CameraChoice { pub camera: Option<String>, pub mic: Option<String> } // None = default

pub struct Camera;   // process-wide, ref-counted like the Mac's acquire/release
impl Camera {
    pub fn acquire(choice: &CameraChoice, preview: Option<PreviewSink>) -> Result<CameraHold, CaptureError>;
}
pub type PreviewSink = Arc<dyn Fn(&[u8] /* JPEG, ≤ 640 px */) + Send + Sync>;
impl CameraHold {   // drop = release
    /// Starts the file; returns the instant its first frame arrived.
    pub fn record(&self, path: &Path) -> Result<Instant, CaptureError>;
    pub fn stop(&self) -> Result<Option<PathBuf>, CaptureError>;  // finished file
}
```

Preview frames arrive ~30 fps as JPEG (the bubble is shown big in 3-2-1 and the editor); the app shows them (blob URL or a
custom protocol). Starting a file restarts the device pipeline once (a short
blink in the preview). Camera with a screen recording: `cameraOffset =
camera first frame − screen first frame`, as the Mac. If the camera fails
the screen still records (`Warning`). The editor's "camera over the video" /
"just me" use `acquire` + `record` + `stop` directly, exactly like the Mac's
EditorModel; file name `camera-<unix>.mp4`.

## Status for Waybar / other processes

`monetshot_capture::status` (ms-app publishes, packaging reads):

```rust
pub struct Status { phase: Phase /* idle|picking|countdown|starting|recording|saving */,
                    countdown: Option<u8>, elapsed: f64, paused: bool, problem: Option<String> }
pub fn publish(s: &Status);                 // atomic write, $XDG_RUNTIME_DIR/monetshot/status.json
pub fn read() -> Option<Status>;            // None: app not running
pub fn waybar_json(s: Option<&Status>) -> String;  // {"text","tooltip","class","alt"}
pub fn follow(f: impl FnMut(Option<&Status>)); // inotify/poll, for `--follow`
```

Omarchy 4 has no Waybar: its bar is omarchy-shell (QML plugins). Both bars
run the same command, so the app side is identical: packaging/omarchy has a
shell plugin (4.x) and a Waybar module (3.x); `install.sh` picks.

ms-app wires the CLI: `monet-shot status --waybar [--follow]` prints
`waybar_json` lines; `monet-shot toggle` (single-instance forward) does what
a click on the tray ring does (idle → record, countdown → cancel, recording
→ stop: a Waybar click is a deliberate act, so it skips hold-to-stop);
`monet-shot pause` toggles pause.

## Platform notes

| | Windows | Linux (portal) | macos-dev |
|---|---|---|---|
| Picker | ours (`list_sources`) | system (portal), restore token | ours |
| Frames | Windows.Graphics.Capture, cursor off, border off where allowed | ScreenCast → PipeWire (SHM) | ffmpeg avfoundation, cursor off |
| Pointer | GetCursorPos 120 Hz, per-monitor DPI v2 | Hyprland IPC `cursorpos` > PipeWire cursor meta > X11 | CGEvent location 120 Hz |
| Clicks | WH_MOUSE_LL | evdev (`input` group) > X11 > none | CGEventSource button state |
| Double Shift | WH_KEYBOARD_LL | evdev > X11 > none | CGEventSource flags (as the Mac) |
| Encode | ffmpeg stdin, nvenc/qsv/amf > libx264 | ffmpeg stdin, vaapi/nvenc > libx264 | ffmpeg (h264_videotoolbox) |

No pointer source → record anyway, `cursor.json` empty, `Warning("…")`;
the editor then draws no cursor and auto-zoom has nothing to work from.
