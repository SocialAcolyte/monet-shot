//! Hyprland's IPC socket (Omarchy): the global pointer, monitors (with
//! scale and the bar's reserved space) and windows. One request per
//! connection, as hyprctl does; cheap enough for 120 Hz.
//!
//! Positions are in Hyprland's layout coordinates (logical pixels).

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

use serde::Deserialize;

pub(crate) fn socket() -> Option<PathBuf> {
    let sig = std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE")?;
    let runtime = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/tmp"));
    let p = runtime.join("hypr").join(&sig).join(".socket.sock");
    if p.exists() {
        return Some(p);
    }
    // Hyprland before 0.40 kept it in /tmp.
    let old = PathBuf::from("/tmp/hypr").join(sig).join(".socket.sock");
    old.exists().then_some(old)
}

pub(crate) struct Hypr {
    path: PathBuf,
}

#[derive(Clone, Debug, Deserialize)]
pub(crate) struct Monitor {
    #[serde(default)]
    pub id: i64,
    pub name: String,
    pub x: f64,
    pub y: f64,
    /// Physical pixels of the mode.
    pub width: f64,
    pub height: f64,
    pub scale: f64,
    #[serde(default)]
    pub transform: i32,
    /// Space taken by bars: [left, top, right, bottom], logical.
    #[serde(default)]
    pub reserved: [f64; 4],
    #[serde(default)]
    pub focused: bool,
}

impl Monitor {
    /// The monitor in layout coordinates.
    pub fn logical(&self) -> (f64, f64, f64, f64) {
        let (w, h) = if self.transform % 2 == 1 { (self.height, self.width) } else { (self.width, self.height) };
        let s = if self.scale > 0.0 { self.scale } else { 1.0 };
        (self.x, self.y, w / s, h / s)
    }
}

#[derive(Clone, Debug, Deserialize)]
pub(crate) struct Client {
    pub address: String,
    pub at: [f64; 2],
    pub size: [f64; 2],
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub class: String,
    #[serde(default, rename = "focusHistoryID")]
    pub focus_history: i32,
    #[serde(default)]
    pub monitor: i64,
}

#[derive(Deserialize)]
struct Pos {
    x: f64,
    y: f64,
}

impl Hypr {
    pub fn connect() -> Option<Hypr> {
        let path = socket()?;
        let h = Hypr { path };
        h.cursor().is_some().then_some(h)
    }

    fn request(&self, cmd: &str) -> Option<Vec<u8>> {
        let mut s = UnixStream::connect(&self.path).ok()?;
        s.set_read_timeout(Some(Duration::from_millis(200))).ok()?;
        s.write_all(cmd.as_bytes()).ok()?;
        let mut out = Vec::new();
        s.read_to_end(&mut out).ok()?;
        Some(out)
    }

    pub fn cursor(&self) -> Option<(f64, f64)> {
        let p: Pos = serde_json::from_slice(&self.request("j/cursorpos")?).ok()?;
        Some((p.x, p.y))
    }

    pub fn monitors(&self) -> Vec<Monitor> {
        self.request("j/monitors").and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    pub fn clients(&self) -> Vec<Client> {
        self.request("j/clients").and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }
}

/// The monitor a portal stream shows: by its reported position, else the
/// one whose pixel size matches, else the focused one.
pub(crate) fn monitor_for(monitors: &[Monitor], position: Option<(i32, i32)>, pixels: (u32, u32)) -> Option<Monitor> {
    if let Some((x, y)) = position {
        if let Some(m) = monitors.iter().find(|m| (m.x - x as f64).abs() < 1.0 && (m.y - y as f64).abs() < 1.0) {
            return Some(m.clone());
        }
    }
    let by_size: Vec<&Monitor> = monitors
        .iter()
        .filter(|m| {
            let (_, _, w, h) = m.logical();
            let (pw, ph) = (w * m.scale, h * m.scale);
            (pw - pixels.0 as f64).abs() <= 2.0 && (ph - pixels.1 as f64).abs() <= 2.0
        })
        .collect();
    if by_size.len() == 1 {
        return Some(by_size[0].clone());
    }
    by_size.iter().find(|m| m.focused).map(|m| (*m).clone()).or_else(|| monitors.iter().find(|m| m.focused).cloned())
}

/// The window a portal window stream shows: the client whose size, at its
/// monitor's scale, matches the stream's pixels; the most recently focused
/// of those (the user was just in it when they picked it).
pub(crate) fn client_for(clients: &[Client], monitors: &[Monitor], pixels: (u32, u32)) -> Option<Client> {
    let scale_of = |c: &Client| monitors.iter().find(|m| m.id == c.monitor).map(|m| m.scale).unwrap_or(1.0);
    let mut fits: Vec<&Client> = clients
        .iter()
        .filter(|c| {
            let s = scale_of(c);
            (c.size[0] * s - pixels.0 as f64).abs() <= 3.0 && (c.size[1] * s - pixels.1 as f64).abs() <= 3.0
        })
        .collect();
    fits.sort_by_key(|c| c.focus_history);
    fits.first().map(|c| (*c).clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    const MONITORS: &str = r#"[{"id":0,"name":"eDP-1","x":0,"y":0,"width":2880,"height":1800,"scale":2.0,"transform":0,"reserved":[0,26,0,0],"focused":true},
        {"id":1,"name":"DP-1","x":1440,"y":0,"width":2560,"height":1440,"scale":1.0,"transform":0,"reserved":[0,26,0,0],"focused":false}]"#;

    #[test]
    fn parses_and_maps_monitors() {
        let m: Vec<Monitor> = serde_json::from_str(MONITORS).unwrap();
        assert_eq!(m[0].logical(), (0.0, 0.0, 1440.0, 900.0));
        assert_eq!(m[0].reserved[1], 26.0);
        assert_eq!(monitor_for(&m, Some((1440, 0)), (0, 0)).unwrap().name, "DP-1");
        assert_eq!(monitor_for(&m, None, (2560, 1440)).unwrap().name, "DP-1");
        assert_eq!(monitor_for(&m, None, (100, 100)).unwrap().name, "eDP-1");
    }

    #[test]
    fn picks_the_recent_client_of_that_size() {
        let c: Vec<Client> = serde_json::from_str(
            r#"[{"address":"0x1","at":[10,40],"size":[800,600],"title":"a","class":"x","focusHistoryID":3,"monitor":0},
                {"address":"0x2","at":[20,40],"size":[800,600],"title":"b","class":"y","focusHistoryID":1,"monitor":0},
                {"address":"0x3","at":[0,0],"size":[400,300],"focusHistoryID":0,"monitor":0}]"#,
        )
        .unwrap();
        assert_eq!(client_for(&c, &[], (800, 600)).unwrap().address, "0x2");
        // On the 2x panel an 800x600 client is 1600x1200 pixels.
        let m: Vec<Monitor> = serde_json::from_str(MONITORS).unwrap();
        assert_eq!(client_for(&c, &m, (1600, 1200)).unwrap().address, "0x2");
        // ...and the 400x300 one is 800x600.
        assert_eq!(client_for(&c, &m, (800, 600)).unwrap().address, "0x3");
        assert!(client_for(&c, &m, (1000, 700)).is_none());
    }
}
