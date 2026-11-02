//! Linux (incl. Omarchy): the xdg-desktop-portal ScreenCast picker →
//! PipeWire frames → ffmpeg. The system cursor is hidden (or sent as
//! metadata); the pointer comes from Hyprland's IPC on Omarchy, else the
//! stream's cursor metadata, else X11. Clicks and double-tap Shift come from
//! evdev (`input` group), or the X11 pointer mask.
//!
//! The portal's restore token is kept, so the next recording of the same
//! content doesn't ask again; `forget_pick` clears it.

mod hypr;
mod input;
mod pw;

use std::os::fd::OwnedFd;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use ashpd::desktop::screencast::{CursorMode, Screencast, SelectSourcesOptions, SourceType, Stream as PortalStream};
use ashpd::desktop::{PersistMode, ResponseError, Session};

use crate::ffmpeg::ffmpeg;
use crate::pipe::Pipe;
use crate::pointer::Bar;
use crate::session::{self, Capture, Shared, Video};
use crate::{
    Backend, Capabilities, CaptureError, CursorSupport, Event, EventSink, Picked, Recording, Source, SourceId, SourceKind,
    StartOptions,
};

pub struct LinuxBackend;

impl LinuxBackend {
    pub fn new() -> Self {
        LinuxBackend
    }
}

impl Default for LinuxBackend {
    fn default() -> Self {
        Self::new()
    }
}

fn token_path() -> PathBuf {
    monetshot_core::paths::state_dir().join("portal-token")
}

/// The portal session, alive from the pick to the end of the recording.
struct PortalPick {
    rt: tokio::runtime::Runtime,
    /// Kept so the D-Bus proxy outlives the session it opened.
    _proxy: Screencast,
    session: Session<Screencast>,
    stream: PortalStream,
    fd: Option<OwnedFd>,
    cursor_mode: CursorMode,
}

impl PortalPick {
    fn close(self) {
        let PortalPick { rt, session, .. } = self;
        let _ = rt.block_on(session.close());
    }
}

fn portal_err(e: ashpd::Error) -> CaptureError {
    CaptureError::Other(format!("screen sharing portal: {e}"))
}

impl Backend for LinuxBackend {
    fn name(&self) -> &'static str {
        "linux-portal"
    }

    fn capabilities(&self) -> Capabilities {
        let hypr = hypr::socket().is_some();
        let x11 = std::env::var("XDG_SESSION_TYPE").ok().as_deref() == Some("x11");
        let evdev = input::evdev_readable();
        let mut notes = Vec::new();
        if !evdev && !x11 {
            notes.push(input::evdev_hint());
        }
        if !hypr && !x11 {
            notes.push("The pointer is only logged while it's over what you record (no Hyprland here).".into());
        }
        Capabilities {
            system_picker: true,
            cursor: if hypr || x11 { CursorSupport::Global } else { CursorSupport::StreamMetadata },
            clicks: evdev || x11,
            double_shift: evdev || x11,
            notes,
        }
    }

    fn list_sources(&self, _thumbnails: bool) -> Result<Vec<Source>, CaptureError> {
        Ok(Vec::new())
    }

    fn choose(&self, _source: &SourceId) -> Result<Picked, CaptureError> {
        Err(CaptureError::Unsupported("Linux uses the system picker: pick()".into()))
    }

    fn forget_pick(&self) {
        let _ = std::fs::remove_file(token_path());
    }

    fn pick(&self) -> Result<Option<Picked>, CaptureError> {
        let rt = tokio::runtime::Builder::new_multi_thread().worker_threads(1).enable_all().build()?;
        let token = std::fs::read_to_string(token_path()).ok().map(|t| t.trim().to_string()).filter(|t| !t.is_empty());
        let r = rt.block_on(async {
            let proxy = Screencast::new().await.map_err(portal_err)?;
            let modes = proxy.available_cursor_modes().await.unwrap_or_default();
            // Metadata gives us the pointer even without Hyprland; Hidden keeps it out of the frames.
            let cursor_mode = if modes.contains(CursorMode::Metadata) {
                CursorMode::Metadata
            } else if modes.contains(CursorMode::Hidden) {
                CursorMode::Hidden
            } else {
                CursorMode::Embedded
            };
            let session = proxy.create_session(Default::default()).await.map_err(portal_err)?;
            proxy
                .select_sources(
                    &session,
                    SelectSourcesOptions::default()
                        .set_cursor_mode(cursor_mode)
                        .set_sources(SourceType::Monitor | SourceType::Window)
                        .set_multiple(false)
                        .set_restore_token(token.as_deref())
                        .set_persist_mode(PersistMode::ExplicitlyRevoked),
                )
                .await
                .map_err(portal_err)?
                .response()
                .map_err(portal_err)?;
            let started = proxy.start(&session, None, Default::default()).await.map_err(portal_err)?.response();
            let streams = match started {
                Ok(s) => s,
                Err(ashpd::Error::Response(ResponseError::Cancelled)) => {
                    let _ = session.close().await;
                    return Ok(None);
                }
                Err(e) => return Err(portal_err(e)),
            };
            if let Some(t) = streams.restore_token() {
                let p = token_path();
                let _ = std::fs::create_dir_all(p.parent().unwrap());
                let _ = std::fs::write(&p, t);
            }
            let Some(stream) = streams.streams().first().cloned() else {
                let _ = session.close().await;
                return Ok(None);
            };
            let fd = proxy.open_pipe_wire_remote(&session, Default::default()).await.map_err(portal_err)?;
            Ok(Some((proxy, session, stream, fd, cursor_mode)))
        });
        let Some((proxy, session, stream, fd, cursor_mode)) = r? else {
            log::info!("picker cancelled");
            return Ok(None);
        };
        let kind = if stream.source_type() == Some(SourceType::Window) { SourceKind::Window } else { SourceKind::Display };
        let size = stream.size().map(|(w, h)| (w.max(0) as u32, h.max(0) as u32)).unwrap_or((0, 0));
        log::info!("portal chose {} {:?} at {:?}, cursor {:?}", kind.meta(), size, stream.position(), cursor_mode);
        let pick = PortalPick { rt, _proxy: proxy, session, stream, fd: Some(fd), cursor_mode };
        Ok(Some(Picked { kind, size, inner: Box::new(pick) }))
    }

    fn start(&self, picked: Picked, opts: StartOptions, on_event: EventSink) -> Result<Recording, CaptureError> {
        let kind = picked.kind;
        let mut pick = *picked.inner.downcast::<PortalPick>().map_err(|_| CaptureError::Other("not a portal source".into()))?;
        let ff = ffmpeg()?;
        let fd = pick.fd.take().ok_or_else(|| CaptureError::Other("this pick was already used".into()))?;
        let (stream, neg) = match pw::PwStream::open(fd, pick.stream.pipe_wire_node_id(), opts.fps) {
            Ok(x) => x,
            Err(e) => {
                pick.close();
                return Err(e);
            }
        };
        let pixels = (neg.width, neg.height);
        let place = Placement::find(kind, pick.stream.position(), pixels);
        let shared = match session::prepare(&opts, kind, place.scale(), on_event) {
            Ok(s) => s,
            Err(e) => {
                stream.stop();
                pick.close();
                return Err(e);
            }
        };
        *shared.bars.lock().unwrap() = place.bars();
        session::start_camera(&shared, &opts);

        let sh = shared.clone();
        let pipe = match Pipe::start(&ff, ff.best_encoder(), &shared.folder.join("screen.mp4"), pixels, neg.format, opts.fps, move |t0| sh.first_frame(t0)) {
            Ok(p) => p,
            Err(e) => {
                stream.stop();
                pick.close();
                session::discard(&shared);
                return Err(e);
            }
        };
        *stream.slot.lock().unwrap() = Some(pipe.slot());

        // The pointer: Hyprland > the stream's cursor metadata > X11.
        let stop = Arc::new(AtomicBool::new(false));
        let mut x11_buttons = false;
        let pointer = match &place {
            Placement::Hypr { .. } => Some(spawn_hypr(shared.clone(), place.clone(), stop.clone())),
            _ => {
                if let Some(x) = input::X11::connect() {
                    x11_buttons = true;
                    Some(spawn_x11(shared.clone(), x, pick.stream.position(), pixels, stop.clone()))
                } else if pick.cursor_mode == CursorMode::Metadata {
                    let sh = shared.clone();
                    let (w, h) = (neg.width.max(1) as f64, neg.height.max(1) as f64);
                    *stream.cursor.lock().unwrap() = Some(Arc::new(move |x, y| sh.position(x / w, y / h)));
                    None
                } else {
                    shared.emit(Event::Warning("No pointer position on this desktop: the video will have no cursor and no auto-zoom.".into()));
                    None
                }
            }
        };
        if pick.cursor_mode == CursorMode::Embedded {
            shared.emit(Event::Warning("This desktop draws its own cursor into the recording.".into()));
        }
        let evdev = if x11_buttons {
            None
        } else {
            let sh = shared.clone();
            let ev = input::Evdev::start(Arc::new(move |s| match s {
                input::Seen::Click(at) => sh.click_here(at),
                input::Seen::Key(k, down) => sh.key(k, down),
            }));
            if ev.is_none() {
                shared.emit(Event::Warning(input::evdev_hint()));
            }
            ev
        };
        log::info!(
            "capture started: {} {}x{} {:?} via {} -> {}",
            kind.meta(),
            neg.width,
            neg.height,
            neg.format,
            ff.best_encoder().name(),
            shared.folder.display()
        );
        let cap = LinuxCapture { stream: Some(stream), pipe: Some(pipe), pointer, evdev, stop, pick: Some(pick), pixels };
        Ok(Recording::new(shared, Box::new(cap)))
    }
}

/// Where the recorded content is in Hyprland's layout, to map the pointer.
#[derive(Clone, Debug)]
#[allow(clippy::large_enum_variant)] // one per recording
enum Placement {
    Hypr { hypr_monitor: Option<hypr::Monitor>, client: Option<hypr::Client>, origin: (f64, f64), size: (f64, f64), scale: f64 },
    Unknown,
}

impl Placement {
    fn find(kind: SourceKind, position: Option<(i32, i32)>, pixels: (u32, u32)) -> Placement {
        let Some(h) = hypr::Hypr::connect() else { return Placement::Unknown };
        let monitors = h.monitors();
        match kind {
            SourceKind::Display => match hypr::monitor_for(&monitors, position, pixels) {
                Some(m) => {
                    log::info!("recording Hyprland monitor {} at {}x scale", m.name, m.scale);
                    let (x, y, w, hh) = m.logical();
                    Placement::Hypr { origin: (x, y), size: (w, hh), scale: m.scale, hypr_monitor: Some(m), client: None }
                }
                None => Placement::Unknown,
            },
            SourceKind::Window => match hypr::client_for(&h.clients(), &monitors, pixels) {
                Some(c) => {
                    log::info!("recording Hyprland window {:?} ({})", c.title, c.class);
                    let scale = monitors.iter().find(|m| m.id == c.monitor).map(|m| m.scale).unwrap_or(1.0);
                    // The file keeps the first size; map by pixels so padding/cropping lines up.
                    let size = (pixels.0 as f64 / scale, pixels.1 as f64 / scale);
                    Placement::Hypr { origin: (c.at[0], c.at[1]), size, scale, hypr_monitor: None, client: Some(c) }
                }
                None => {
                    log::info!("couldn't tell which Hyprland window is shared; the pointer comes from the stream if it can");
                    Placement::Unknown
                }
            },
        }
    }

    fn scale(&self) -> f64 {
        match self {
            Placement::Hypr { scale, .. } => *scale,
            Placement::Unknown => 1.0,
        }
    }

    /// Waybar's reserved edge (Omarchy: the top) and the pill under it.
    fn bars(&self) -> Vec<Bar> {
        let Placement::Hypr { hypr_monitor: Some(m), size: (w, h), .. } = self else { return Vec::new() };
        let [l, t, r, b] = m.reserved;
        let mut bars = vec![Bar::Top((t + 56.0) / h.max(1.0))];
        if b > 0.0 {
            bars.push(Bar::Bottom(b / h.max(1.0)));
        }
        if l > 0.0 {
            bars.push(Bar::Left(l / w.max(1.0)));
        }
        if r > 0.0 {
            bars.push(Bar::Right(r / w.max(1.0)));
        }
        bars
    }
}

fn spawn_hypr(shared: Arc<Shared>, place: Placement, stop: Arc<AtomicBool>) -> JoinHandle<()> {
    std::thread::Builder::new()
        .name("monetshot-pointer".into())
        .spawn(move || {
            let Some(h) = hypr::Hypr::connect() else { return };
            let Placement::Hypr { client, mut origin, size, .. } = place else { return };
            let period = Duration::from_secs_f64(1.0 / 120.0);
            let mut next = Instant::now();
            let mut n: u64 = 0;
            while !stop.load(Ordering::SeqCst) {
                // A recorded window can move: follow it 4 times a second.
                if let (Some(c), true) = (&client, n.is_multiple_of(30)) {
                    if let Some(now) = h.clients().into_iter().find(|x| x.address == c.address) {
                        origin = (now.at[0], now.at[1]);
                    }
                }
                n += 1;
                if let Some((x, y)) = h.cursor() {
                    shared.position((x - origin.0) / size.0.max(1.0), (y - origin.1) / size.1.max(1.0));
                }
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

fn spawn_x11(shared: Arc<Shared>, x: input::X11, position: Option<(i32, i32)>, pixels: (u32, u32), stop: Arc<AtomicBool>) -> JoinHandle<()> {
    std::thread::Builder::new()
        .name("monetshot-pointer".into())
        .spawn(move || {
            let (ox, oy) = position.map(|(a, b)| (a as f64, b as f64)).unwrap_or((0.0, 0.0));
            let (w, h) = (pixels.0.max(1) as f64, pixels.1.max(1) as f64);
            let period = Duration::from_secs_f64(1.0 / 120.0);
            let mut was_down = false;
            while !stop.load(Ordering::SeqCst) {
                if let Some(s) = x.query() {
                    let (nx, ny) = ((s.x - ox) / w, (s.y - oy) / h);
                    shared.position(nx, ny);
                    if s.buttons && !was_down {
                        shared.click(nx, ny);
                    }
                    was_down = s.buttons;
                    shared.modifiers(s.shift, s.others);
                }
                std::thread::sleep(period);
            }
        })
        .expect("pointer thread")
}

struct LinuxCapture {
    stream: Option<pw::PwStream>,
    pipe: Option<Pipe>,
    pointer: Option<JoinHandle<()>>,
    evdev: Option<input::Evdev>,
    stop: Arc<AtomicBool>,
    pick: Option<PortalPick>,
    pixels: (u32, u32),
}

impl LinuxCapture {
    fn halt(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(p) = self.pointer.take() {
            let _ = p.join();
        }
        if let Some(e) = self.evdev.take() {
            e.stop();
        }
        if let Some(s) = self.stream.take() {
            s.stop();
        }
        if let Some(p) = self.pick.take() {
            p.close();
        }
    }
}

impl Capture for LinuxCapture {
    fn finish(mut self: Box<Self>) -> Result<Video, CaptureError> {
        self.halt();
        let r = self.pipe.take().expect("pipe").finish()?;
        let (w, h) = crate::pipe::even(self.pixels.0, self.pixels.1);
        Ok(Video { file: r.file, width: w, height: h, duration: r.duration })
    }

    fn abort(mut self: Box<Self>) {
        self.halt();
        if let Some(p) = self.pipe.take() {
            let _ = p.finish();
        }
    }
}
