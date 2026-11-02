//! The app's side of recording: drives `monetshot-capture` and turns what it
//! reports into `bar::Event`s (docs/porting/contracts/capture.md).
//!
//! Capture calls block, so each runs on its own thread; results come back
//! to the bar on the main thread.

use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

use monetshot_capture::{self as capture, Backend, Picked, Recording, SourceId, StartOptions};
use serde::Serialize;
use tauri::{AppHandle, Manager};

use crate::bar::Bar;
use crate::{log, windows};

#[derive(Debug)]
pub enum Event {
    /// The picker closed without a choice.
    PickerClosed,
    /// A display or window was chosen: count in.
    Picked,
    /// Frames are being written.
    Started,
    Paused(bool),
    /// A new recording is saved: open it.
    Finished { folder: PathBuf },
    /// A take recorded into `project` is saved, bringing `clips`.
    FinishedTake { project: PathBuf, clips: Vec<monetshot_core::Clip> },
    Failed(String),
}

struct State {
    /// The chosen content, held through the 3-2-1.
    picked: Option<Picked>,
    /// Kept until Finished/Failed: dropping an unstopped Recording deletes it.
    recording: Option<Arc<Recording>>,
    /// Bumped by every pick and cancel, so a picker that returns late is ignored.
    pick_gen: u64,
}

static STATE: Mutex<State> = Mutex::new(State { picked: None, recording: None, pick_gen: 0 });

fn backend() -> &'static dyn Backend {
    static B: OnceLock<Box<dyn Backend>> = OnceLock::new();
    B.get_or_init(|| {
        let b = capture::backend();
        let caps = b.capabilities();
        log::info(&format!("capture backend {}: {:?}", b.name(), caps));
        b
    })
    .as_ref()
}

fn send(app: &AppHandle, e: Event) {
    let app2 = app.clone();
    let _ = app.run_on_main_thread(move || app2.state::<Bar>().handle(&app2, e));
}

fn next_gen() -> u64 {
    let mut s = STATE.lock().unwrap();
    s.pick_gen += 1;
    s.picked = None;
    s.pick_gen
}

/// The system picker (Linux portal), or ours (Windows, macos-dev).
pub fn pick(app: &AppHandle) {
    let gen = next_gen();
    if backend().capabilities().system_picker {
        let app = app.clone();
        std::thread::spawn(move || {
            let r = backend().pick();
            picked(&app, gen, r.map_err(|e| e.to_string()));
        });
    } else if std::env::var_os("MONETSHOT_DEMO_RECORD").is_some() {
        // Developer aid: the demo records the first display, no picker.
        let first = backend().list_sources(false).ok().and_then(|l| l.into_iter().next());
        choose(app, first.map(|s| s.id.0));
    } else {
        windows::show_picker(app);
    }
}

/// Whether the system picker remembers the last choice (Linux portal), so
/// the tray offers "Choose what to record…" to pick again.
pub fn remembers_pick() -> bool {
    backend().capabilities().system_picker
}

/// Forget the remembered choice, so the next pick shows the dialog.
pub fn forget_pick() {
    backend().forget_pick();
}

/// A source from our own picker; None when it was closed.
pub fn choose(app: &AppHandle, id: Option<String>) {
    let gen = STATE.lock().unwrap().pick_gen;
    windows::close_picker(app);
    let Some(id) = id else {
        picked(app, gen, Ok(None));
        return;
    };
    let app = app.clone();
    std::thread::spawn(move || {
        let r = backend().choose(&SourceId(id)).map(Some);
        picked(&app, gen, r.map_err(|e| e.to_string()));
    });
}

fn picked(app: &AppHandle, gen: u64, r: Result<Option<Picked>, String>) {
    {
        let mut s = STATE.lock().unwrap();
        if s.pick_gen != gen {
            return;
        }
        if let Ok(Some(p)) = &r {
            log::info(&format!("picked {:?}", p));
        }
        if let Ok(Some(p)) = r {
            s.picked = Some(p);
            drop(s);
            send(app, Event::Picked);
            return;
        }
    }
    match r {
        Err(e) => send(app, Event::Failed(format!("pick: {e}"))),
        _ => send(app, Event::PickerClosed),
    }
}

pub fn cancel_pending(app: &AppHandle) {
    next_gen();
    windows::close_picker(app);
}

/// After the 3-2-1.
pub fn begin_recording(app: &AppHandle, take_into: Option<PathBuf>, camera_too: bool) {
    let Some(picked) = STATE.lock().unwrap().picked.take() else {
        send(app, Event::Failed("nothing picked".into()));
        return;
    };
    let app = app.clone();
    std::thread::spawn(move || {
        let mut opts = StartOptions::new(monetshot_core::paths::library_dir());
        opts.take_into = take_into;
        opts.camera = camera_too.then(crate::camera::choice);
        let sink_app = app.clone();
        let sink: capture::EventSink = Arc::new(move |e| on_capture(&sink_app, e));
        match backend().start(picked, opts, sink) {
            Ok(rec) => {
                log::info(&format!("recording into {}", rec.folder().display()));
                STATE.lock().unwrap().recording = Some(Arc::new(rec));
            }
            Err(e) => send(&app, Event::Failed(format!("start: {e}"))),
        }
    });
}

fn on_capture(app: &AppHandle, e: capture::Event) {
    match e {
        capture::Event::Started => send(app, Event::Started),
        capture::Event::Tick { .. } => {}
        capture::Event::Paused(on) => send(app, Event::Paused(on)),
        capture::Event::Warning(w) => log::info(&format!("capture warning: {w}")),
        capture::Event::Finished { folder } => {
            STATE.lock().unwrap().recording = None;
            send(app, Event::Finished { folder });
        }
        capture::Event::FinishedTake { project, clips, .. } => {
            STATE.lock().unwrap().recording = None;
            send(app, Event::FinishedTake { project, clips });
        }
        capture::Event::Failed(m) => {
            STATE.lock().unwrap().recording = None;
            send(app, Event::Failed(m));
        }
    }
}

fn current() -> Option<Arc<Recording>> {
    STATE.lock().unwrap().recording.clone()
}

pub fn toggle_pause(_app: &AppHandle) {
    if let Some(r) = current() {
        r.toggle_pause();
    }
}

pub fn stop(_app: &AppHandle) {
    // stop() may block while the file is finished; Finished follows by
    // event, so the lock isn't held meanwhile.
    std::thread::spawn(|| {
        if let Some(r) = current() {
            r.stop();
        }
    });
}

/// Quitting mid-take: finish it so nothing recorded is lost.
pub fn stop_blocking() {
    if let Some(r) = current() {
        r.stop();
    }
}

/// A source for our picker page.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceView {
    id: String,
    kind: &'static str,
    title: String,
    app: Option<String>,
    width: f64,
    height: f64,
    /// `data:image/png;base64,…`, or None.
    thumbnail: Option<String>,
}

pub fn sources() -> Result<Vec<SourceView>, String> {
    let list = backend().list_sources(true).map_err(|e| e.to_string())?;
    Ok(list
        .into_iter()
        .map(|s| SourceView {
            id: s.id.0,
            kind: s.kind.meta(),
            title: s.title,
            app: s.app,
            width: s.bounds.width,
            height: s.bounds.height,
            thumbnail: s.thumbnail.map(|t| format!("data:image/png;base64,{}", base64(&t.png))),
        })
        .collect())
}

fn base64(bytes: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for c in bytes.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        for i in 0..4 {
            if i <= c.len() {
                out.push(T[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    #[test]
    fn base64_pads() {
        assert_eq!(super::base64(b"Ma"), "TWE=");
        assert_eq!(super::base64(b"Man"), "TWFu");
        assert_eq!(super::base64(b"M"), "TQ==");
    }
}
