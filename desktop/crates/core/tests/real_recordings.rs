//! Connor's real recordings (read-only): every meta/cursor/edit.json must
//! load and re-encode to exactly the bytes the Mac wrote. Skipped when the
//! folder isn't there (CI, other machines). MONETSHOT_REAL_LIBRARY overrides.

use monetshot_core::json::{from_json, to_swift_json};
use monetshot_core::{CursorTrack, EditDoc, Project, RecordingMeta};
use std::path::PathBuf;

fn library() -> Option<PathBuf> {
    let dir = std::env::var_os("MONETSHOT_REAL_LIBRARY")
        .map(PathBuf::from)
        .or_else(|| dirs_home().map(|h| h.join("Movies/MonetShot")))?;
    dir.is_dir().then_some(dir)
}

fn dirs_home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

fn same<T: serde::de::DeserializeOwned + serde::Serialize>(path: &PathBuf) -> Result<(), String> {
    let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
    let v: T = from_json(&bytes).map_err(|e| format!("{}: {e}", path.display()))?;
    let back = to_swift_json(&v).unwrap();
    if back.as_bytes() != bytes.as_slice() {
        let a = String::from_utf8_lossy(&bytes);
        let line = a.lines().zip(back.lines()).position(|(x, y)| x != y).unwrap_or(0);
        return Err(format!(
            "{} differs at line {}:\n  mac:  {:?}\n  rust: {:?}",
            path.display(),
            line + 1,
            a.lines().nth(line),
            back.lines().nth(line)
        ));
    }
    Ok(())
}

#[test]
fn real_recordings_round_trip_byte_for_byte() {
    let Some(lib) = library() else {
        eprintln!("no library; skipped");
        return;
    };
    let mut errors = vec![];
    let mut files = 0;
    let mut projects = 0;
    for reel in monetshot_core::project::list_recordings(&lib) {
        let mut dirs = vec![reel.clone()];
        dirs.extend(monetshot_core::project::take_folders(&reel));
        for d in &dirs {
            for (name, check) in [
                ("meta.json", same::<RecordingMeta> as fn(&PathBuf) -> Result<(), String>),
                ("cursor.json", same::<CursorTrack>),
                ("edit.json", same::<EditDoc>),
            ] {
                let p = d.join(name);
                if p.exists() {
                    files += 1;
                    if let Err(e) = check(&p) {
                        errors.push(e);
                    }
                }
            }
        }
        if let Ok(p) = Project::load(&reel) {
            projects += 1;
            let planner = monetshot_core::Planner::from_project(&p);
            let d = planner.duration();
            for i in 0..=10 {
                let plan = planner.plan(d * i as f64 / 10.0);
                assert!(plan.frame.w > 0.0 && plan.source.rect.w > 0.0);
            }
        }
    }
    eprintln!("{files} files, {projects} projects loaded from {}", lib.display());
    assert!(errors.is_empty(), "{}", errors.join("\n"));
}
