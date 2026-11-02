//! Where the app keeps things, per OS. `MONETSHOT_HOME` overrides all of
//! them, as on the Mac: `<home>/recordings`, `<home>/support`, `<home>/logs`.
//!
//! | | recordings | config/state | logs |
//! |---|---|---|---|
//! | Linux | `$(xdg-user-dir VIDEOS)/MonetShot` | `~/.config/MonetShot` | `~/.local/share/MonetShot/logs` |
//! | Windows | `%USERPROFILE%\Videos\MonetShot` | `%APPDATA%\MonetShot` | `%LOCALAPPDATA%\MonetShot\logs` |
//! | macOS (dev) | `~/Movies/MonetShot` | `~/Library/Application Support/MonetShot` | `~/Library/Logs/MonetShot` |

use std::path::PathBuf;

pub const APP_NAME: &str = "MonetShot";

fn override_home() -> Option<PathBuf> {
    std::env::var_os("MONETSHOT_HOME").filter(|v| !v.is_empty()).map(PathBuf::from)
}

fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_else(|| PathBuf::from("."))
}

/// Where new recordings go.
pub fn library_dir() -> PathBuf {
    if let Some(h) = override_home() {
        return h.join("recordings");
    }
    // dirs reads XDG user-dirs on Linux and FOLDERID_Videos on Windows.
    dirs::video_dir().unwrap_or_else(|| home().join("Videos")).join(APP_NAME)
}

/// config.json, state.json and other small files the app owns.
pub fn support_dir() -> PathBuf {
    if let Some(h) = override_home() {
        return h.join("support");
    }
    dirs::config_dir().unwrap_or_else(|| home().join(".config")).join(APP_NAME)
}

/// Same folder as `support_dir` (state.json, the portal restore token).
pub fn state_dir() -> PathBuf {
    support_dir()
}

pub fn log_dir() -> PathBuf {
    if let Some(h) = override_home() {
        return h.join("logs");
    }
    if cfg!(target_os = "macos") {
        return home().join("Library/Logs").join(APP_NAME);
    }
    dirs::data_local_dir().unwrap_or_else(|| home().join(".local/share")).join(APP_NAME).join("logs")
}

/// `monetshot.log` in `log_dir()`.
pub fn log_file() -> PathBuf {
    log_dir().join(format!("{}.log", APP_NAME.to_lowercase()))
}

pub fn config_file() -> PathBuf {
    support_dir().join("config.json")
}

pub fn state_file() -> PathBuf {
    support_dir().join("state.json")
}
