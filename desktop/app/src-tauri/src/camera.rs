//! The one camera, shared like the Mac's `CameraRecorder.shared`: the bubble
//! during a 3-2-1 and the editor's camera both hold it, and every page that
//! shows it gets the same preview frames (JPEG, ~30 fps) over a channel.
//! The webview never opens the camera itself (it's exclusive on v4l2 and
//! most Windows drivers).

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use monetshot_capture::{Camera, CameraChoice, CameraHold};
use tauri::ipc::{Channel, InvokeResponseBody};

use crate::log;

struct Shared {
    hold: Option<CameraHold>,
    /// Who holds it ("bar", an editor's label).
    owners: BTreeSet<String>,
}

static SHARED: Mutex<Shared> = Mutex::new(Shared { hold: None, owners: BTreeSet::new() });
static VIEWERS: Mutex<Vec<Channel<InvokeResponseBody>>> = Mutex::new(Vec::new());

/// The camera and microphone to use, remembered across launches (the Mac
/// keeps its choice in UserDefaults). None = the system default.
pub fn choice() -> CameraChoice {
    std::fs::read(choice_file())
        .ok()
        .and_then(|b| serde_json::from_slice::<(Option<String>, Option<String>)>(&b).ok())
        .map(|(camera, mic)| CameraChoice { camera, mic })
        .unwrap_or_default()
}

fn choice_file() -> PathBuf {
    monetshot_core::paths::state_dir().join("camera.json")
}

fn preview_sink() -> monetshot_capture::PreviewSink {
    Arc::new(|jpeg: &[u8]| {
        let mut v = VIEWERS.lock().unwrap();
        v.retain(|c| c.send(InvokeResponseBody::Raw(jpeg.to_vec())).is_ok());
    })
}

/// Turns the camera on for `owner` (blocks while it starts). False if it can't.
pub fn acquire(owner: &str) -> bool {
    let mut s = SHARED.lock().unwrap();
    if s.hold.is_none() {
        match Camera::acquire(&choice(), Some(preview_sink())) {
            Ok(h) => s.hold = Some(h),
            Err(e) => {
                log::error(&format!("camera: {e}"));
                return false;
            }
        }
    }
    s.owners.insert(owner.to_string());
    true
}

/// Switches camera (and mic) and remembers it. If the camera is on, it comes
/// back on with the new device (not while it's recording).
pub fn use_device(camera: Option<String>, mic: Option<String>) -> Result<(), String> {
    let c = CameraChoice { camera, mic };
    let p = choice_file();
    let _ = std::fs::create_dir_all(p.parent().unwrap());
    std::fs::write(&p, serde_json::to_vec(&(&c.camera, &c.mic)).unwrap()).map_err(|e| e.to_string())?;
    let mut s = SHARED.lock().unwrap();
    if s.hold.is_some() {
        // A hold with a different choice restarts the device for everyone.
        let fresh = Camera::acquire(&c, Some(preview_sink())).map_err(|e| e.to_string())?;
        s.hold = Some(fresh);
    }
    Ok(())
}

pub fn release(owner: &str) {
    let mut s = SHARED.lock().unwrap();
    if s.owners.remove(owner) && s.owners.is_empty() {
        s.hold = None;
        VIEWERS.lock().unwrap().clear();
    }
}

/// A page wants the preview frames.
pub fn watch(c: Channel<InvokeResponseBody>) {
    VIEWERS.lock().unwrap().push(c);
}

/// Starts a file; the instant its first frame arrived.
pub fn record(path: &Path) -> Result<Instant, String> {
    let s = SHARED.lock().unwrap();
    let h = s.hold.as_ref().ok_or("the camera is off")?;
    h.record(path).map_err(|e| e.to_string())
}

pub fn stop() -> Option<PathBuf> {
    let s = SHARED.lock().unwrap();
    s.hold.as_ref()?.stop().map_err(|e| log::error(&format!("camera stop: {e}"))).ok().flatten()
}
