//! The recorder's state for other processes: Waybar's custom module on
//! Omarchy (`monet-shot status --waybar --follow`) and anything else that
//! wants to show it. The app publishes; a small JSON file, written atomically.

use std::path::PathBuf;
use std::time::Duration;

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Phase {
    #[default]
    Idle,
    Picking,
    Countdown,
    Starting,
    Recording,
    Saving,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Status {
    pub phase: Phase,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub countdown: Option<u8>,
    /// Recorded seconds, pauses not counted.
    #[serde(default)]
    pub elapsed: f64,
    #[serde(default)]
    pub paused: bool,
    /// "Couldn't record", shown for a few seconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub problem: Option<String>,
    /// The app's process, so a stale file from a crash reads as "not running".
    #[serde(default)]
    pub pid: u32,
}

/// `$XDG_RUNTIME_DIR/monetshot/status.json` (gone on logout), else the temp dir.
pub fn path() -> PathBuf {
    let base = std::env::var_os("MONETSHOT_HOME")
        .map(|h| PathBuf::from(h).join("run"))
        .or_else(|| std::env::var_os("XDG_RUNTIME_DIR").map(|d| PathBuf::from(d).join("monetshot")))
        .unwrap_or_else(|| std::env::temp_dir().join("monetshot"));
    base.join("status.json")
}

/// Writes the status for readers. Errors are logged, never fatal.
pub fn publish(s: &Status) {
    let mut s = s.clone();
    s.pid = std::process::id();
    let p = path();
    let write = || -> std::io::Result<()> {
        std::fs::create_dir_all(p.parent().unwrap())?;
        let tmp = p.with_extension(format!("json.{}", s.pid));
        std::fs::write(&tmp, serde_json::to_vec(&s)?)?;
        std::fs::rename(&tmp, &p)
    };
    if let Err(e) = write() {
        log::error!("status: {e}");
    }
}

/// The app clears its status on quit.
pub fn clear() {
    let _ = std::fs::remove_file(path());
}

/// The current status; None when Monet Shot isn't running.
pub fn read() -> Option<Status> {
    let s: Status = serde_json::from_slice(&std::fs::read(path()).ok()?).ok()?;
    alive(s.pid).then_some(s)
}

#[cfg(unix)]
fn alive(pid: u32) -> bool {
    pid == 0 || PathBuf::from(format!("/proc/{pid}")).exists() || !cfg!(target_os = "linux")
}

#[cfg(not(unix))]
fn alive(_pid: u32) -> bool {
    true
}

/// "0:07", "12:41", "1:02:03", as the Mac's menu bar clock.
pub fn clock(seconds: f64) -> String {
    let s = seconds.max(0.0) as u64;
    if s >= 3600 {
        format!("{}:{:02}:{:02}", s / 3600, s / 60 % 60, s % 60)
    } else {
        format!("{}:{:02}", s / 60, s % 60)
    }
}

/// One line for Waybar's custom module (`"return-type": "json"`). `class`
/// drives the style (see packaging/omarchy/waybar.css); `alt` the format-icons.
pub fn waybar_json(s: Option<&Status>) -> String {
    let (text, tooltip, class) = match s {
        None => ("".to_string(), "Monet Shot isn't running".to_string(), "off"),
        Some(s) if s.problem.is_some() => ("".to_string(), s.problem.clone().unwrap_or_default(), "problem"),
        Some(s) => match s.phase {
            Phase::Idle => ("".into(), "Record the screen".into(), "idle"),
            Phase::Picking => ("".into(), "Choose what to record".into(), "picking"),
            Phase::Countdown => (s.countdown.map(|n| n.to_string()).unwrap_or_default(), "Starting… click to cancel".into(), "countdown"),
            Phase::Starting => ("".into(), "Starting…".into(), "countdown"),
            Phase::Recording if s.paused => (clock(s.elapsed), "Paused: double-tap Shift to go on, click to stop".into(), "paused"),
            Phase::Recording => (clock(s.elapsed), "Recording: click to stop, double-tap Shift to pause".into(), "recording"),
            Phase::Saving => ("".into(), "Saving…".into(), "saving"),
        },
    };
    serde_json::json!({ "text": text, "tooltip": tooltip, "class": class, "alt": class }).to_string()
}

/// Calls `f` with the status now and on every change until `f` returns
/// false. Polls the file's mtime (cheap, portable; 4 Hz is plenty for a bar).
pub fn follow(mut f: impl FnMut(Option<&Status>) -> bool) {
    let mut last: Option<Option<Status>> = None;
    loop {
        let now = read();
        if last.as_ref() != Some(&now) {
            if !f(now.as_ref()) {
                return;
            }
            last = Some(now);
        }
        std::thread::sleep(Duration::from_millis(250));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clock_matches_the_mac() {
        assert_eq!(clock(7.9), "0:07");
        assert_eq!(clock(761.0), "12:41");
        assert_eq!(clock(3723.0), "1:02:03");
    }

    #[test]
    fn waybar_classes() {
        let s = Status { phase: Phase::Recording, elapsed: 65.0, ..Default::default() };
        let j: serde_json::Value = serde_json::from_str(&waybar_json(Some(&s))).unwrap();
        assert_eq!(j["text"], "1:05");
        assert_eq!(j["class"], "recording");
        let s = Status { phase: Phase::Countdown, countdown: Some(2), ..Default::default() };
        let j: serde_json::Value = serde_json::from_str(&waybar_json(Some(&s))).unwrap();
        assert_eq!(j["text"], "2");
        let j: serde_json::Value = serde_json::from_str(&waybar_json(None)).unwrap();
        assert_eq!(j["class"], "off");
    }
}
