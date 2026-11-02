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
