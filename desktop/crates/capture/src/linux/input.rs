//! Clicks and double-tap Shift on Linux. Wayland gives an app no global
//! input, so this reads the kernel's evdev devices, which needs read access
//! to /dev/input (the `input` group). X11 sessions poll the pointer and its
//! button/modifier mask instead, as the Mac polls CoreGraphics.

use std::path::PathBuf;
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use evdev::{EventSummary, KeyCode};

use crate::pointer::Key;

#[derive(Clone, Copy, Debug)]
pub(crate) enum Seen {
    Click(Instant),
    Key(Key, bool),
}

pub(crate) type InputSink = Arc<dyn Fn(Seen) + Send + Sync>;

/// A touchpad tap shorter than this is taken as a click (tap-to-click is
/// done by libinput above evdev, so the kernel never reports a button).
const TAP: Duration = Duration::from_millis(180);

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Pointer,
    Touchpad,
    Keyboard,
}

fn kinds(d: &evdev::Device) -> Vec<Kind> {
    let Some(keys) = d.supported_keys() else { return Vec::new() };
    let mut k = Vec::new();
    if keys.contains(KeyCode::BTN_LEFT) {
        k.push(Kind::Pointer);
    }
    if keys.contains(KeyCode::BTN_TOOL_FINGER) && keys.contains(KeyCode::BTN_TOUCH) {
        k.push(Kind::Touchpad);
    }
    if keys.contains(KeyCode::KEY_LEFTSHIFT) && keys.contains(KeyCode::KEY_A) {
        k.push(Kind::Keyboard);
    }
    k
}

/// The devices we can read: (path, what they are).
fn devices() -> Vec<(PathBuf, evdev::Device, Vec<Kind>)> {
    evdev::enumerate().filter_map(|(p, d)| { let k = kinds(&d); (!k.is_empty()).then_some((p, d, k)) }).collect()
}

/// Can we see clicks and keys? (Some event devices readable.)
pub(crate) fn evdev_readable() -> bool {
    let all = devices();
    all.iter().any(|(_, _, k)| k.contains(&Kind::Pointer) || k.contains(&Kind::Touchpad))
        && all.iter().any(|(_, _, k)| k.contains(&Kind::Keyboard))
}

/// Why clicks are missing, for the UI.
pub(crate) fn evdev_hint() -> String {
    "Clicks and double-tap Shift need read access to input devices: run `sudo usermod -aG input $USER`, then log out and back in.".into()
}

pub(crate) struct Evdev {
    stop: tokio::sync::watch::Sender<bool>,
    thread: Option<JoinHandle<()>>,
}

impl Evdev {
    pub fn start(sink: InputSink) -> Option<Evdev> {
        let devs = devices();
        if devs.is_empty() {
            return None;
        }
        let (stop, rx) = tokio::sync::watch::channel(false);
        let thread = std::thread::Builder::new()
            .name("monetshot-evdev".into())
            .spawn(move || {
                let rt = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
                    Ok(rt) => rt,
                    Err(e) => return log::error!("evdev: {e}"),
                };
                rt.block_on(async move {
                    let mut tasks = Vec::new();
                    for (path, dev, kinds) in devs {
                        let Ok(mut events) = dev.into_event_stream() else { continue };
                        let (sink, mut rx) = (sink.clone(), rx.clone());
                        log::info!("evdev: {}", path.display());
                        tasks.push(tokio::spawn(async move {
                            let touchpad = kinds.contains(&Kind::Touchpad);
                            let mut touch_at: Option<Instant> = None;
                            let mut pressed_since_touch = false;
                            loop {
                                tokio::select! {
                                    _ = rx.changed() => return,
                                    e = events.next_event() => {
                                        let Ok(e) = e else { return };
                                        let EventSummary::Key(_, code, value) = e.destructure() else { continue };
                                        let now = Instant::now();
                                        match code {
                                            KeyCode::BTN_LEFT | KeyCode::BTN_RIGHT => {
                                                if value == 1 {
                                                    pressed_since_touch = true;
                                                    sink(Seen::Click(now));
                                                }
                                            }
                                            KeyCode::BTN_TOUCH if touchpad => {
                                                if value == 1 {
                                                    touch_at = Some(now);
                                                    pressed_since_touch = false;
                                                } else if value == 0 {
                                                    if let Some(at) = touch_at.take() {
                                                        if now - at < TAP && !pressed_since_touch {
                                                            sink(Seen::Click(at));
                                                        }
                                                    }
                                                }
                                            }
                                            // value 2 is auto-repeat: not a new press.
                                            KeyCode::KEY_LEFTSHIFT | KeyCode::KEY_RIGHTSHIFT if value != 2 => {
                                                sink(Seen::Key(Key::Shift, value == 1));
                                            }
                                            // Keyboard keys only; buttons and tool codes start at BTN_MISC.
                                            c if c.0 < 0x100 && value != 2 => {
                                                sink(Seen::Key(Key::Other, value == 1));
                                            }
                                            _ => {}
                                        }
                                    }
                                }
                            }
                        }));
                    }
                    for t in tasks {
                        let _ = t.await;
                    }
                });
            })
            .ok()?;
        Some(Evdev { stop, thread: Some(thread) })
    }

    pub fn stop(mut self) {
        let _ = self.stop.send(true);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

/// The X11 pointer: root position and the button/modifier mask.
pub(crate) struct X11 {
    conn: x11rb::rust_connection::RustConnection,
    root: u32,
}

pub(crate) struct X11State {
    pub x: f64,
    pub y: f64,
    pub buttons: bool,
    pub shift: bool,
    pub others: bool,
}

impl X11 {
    /// Only on an X11 session: under Wayland, XWayland sees the pointer
    /// only over X windows.
    pub fn connect() -> Option<X11> {
        if std::env::var("XDG_SESSION_TYPE").ok().as_deref() != Some("x11") {
            return None;
        }
        let (conn, screen) = x11rb::connect(None).ok()?;
        let root = x11rb::connection::Connection::setup(&conn).roots.get(screen)?.root;
        Some(X11 { conn, root })
    }

    pub fn query(&self) -> Option<X11State> {
        use x11rb::protocol::xproto::{ConnectionExt, KeyButMask};
        let r = self.conn.query_pointer(self.root).ok()?.reply().ok()?;
        let m = r.mask;
        Some(X11State {
            x: r.root_x as f64,
            y: r.root_y as f64,
            buttons: m.contains(KeyButMask::BUTTON1) || m.contains(KeyButMask::BUTTON3),
            shift: m.contains(KeyButMask::SHIFT),
            others: m.contains(KeyButMask::CONTROL) || m.contains(KeyButMask::MOD1) || m.contains(KeyButMask::MOD4),
        })
    }
}
