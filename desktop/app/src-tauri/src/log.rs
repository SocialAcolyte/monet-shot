//! Plain-text log, one line per event, as the Mac's `Log`.

use std::io::Write;
use std::sync::Mutex;

static LOCK: Mutex<()> = Mutex::new(());

fn write(level: &str, msg: &str) {
    let _g = LOCK.lock();
    let line = format!("{} {level} {msg}\n", stamp());
    eprint!("{line}");
    let path = monetshot_core::paths::log_file();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = f.write_all(line.as_bytes());
    }
}

/// Seconds since the epoch, UTC: no time-zone crate for a log line.
fn stamp() -> String {
    let ms = crate::bar::now_ms();
    format!("{}.{:03}", ms / 1000, ms % 1000)
}

pub fn info(msg: &str) {
    write("INFO", msg)
}

pub fn error(msg: &str) {
    write("ERROR", msg)
}

/// Records from the `log` crate (the capture and export crates use it: the
/// encoder chosen, capture warnings, pauses) go to this log too. Ours at
/// info and above, debug with MONETSHOT_DEBUG=1; other crates' (tauri,
/// wry, …) only from warn up.
struct Bridge;

static BRIDGE: Bridge = Bridge;

fn ours(target: &str) -> bool {
    target.starts_with("monetshot") || target.starts_with("monet_shot")
}

impl ::log::Log for Bridge {
    fn enabled(&self, m: &::log::Metadata) -> bool {
        m.level() <= if ours(m.target()) { ::log::max_level() } else { ::log::LevelFilter::Warn }
    }
    fn log(&self, r: &::log::Record) {
        if !self.enabled(r.metadata()) {
            return;
        }
        let level = match r.level() {
            ::log::Level::Error => "ERROR",
            ::log::Level::Warn => "WARN",
            ::log::Level::Info => "INFO",
            ::log::Level::Debug => "DEBUG",
            ::log::Level::Trace => "TRACE",
        };
        let from = r.target().split("::").next().unwrap_or("");
        write(level, &format!("{from}: {}", r.args()));
    }
    fn flush(&self) {}
}

/// Installs the bridge; once, first thing.
pub fn install() {
    let max = if std::env::var_os("MONETSHOT_DEBUG").is_some() { ::log::LevelFilter::Debug } else { ::log::LevelFilter::Info };
    if ::log::set_logger(&BRIDGE).is_ok() {
        ::log::set_max_level(max);
    }
}
