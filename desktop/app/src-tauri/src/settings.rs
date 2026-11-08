//! The app's own small settings (not the edit): config.json in the config
//! dir, owner-only, written atomically. Unknown keys are kept.

use serde_json::{Map, Value};

fn path() -> std::path::PathBuf {
    monetshot_core::paths::config_file()
}

fn load() -> Map<String, Value> {
    std::fs::read(path())
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .and_then(|v| v.as_object().cloned())
        .unwrap_or_default()
}

fn save(map: &Map<String, Value>) {
    let p = path();
    let Some(dir) = p.parent() else { return };
    let _ = std::fs::create_dir_all(dir);
    let tmp = p.with_extension("json.tmp");
    let Ok(bytes) = serde_json::to_vec_pretty(map) else { return };
    if std::fs::write(&tmp, bytes).is_ok() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
        }
        let _ = std::fs::rename(&tmp, &p);
    }
}

/// "Record My Camera Too", remembered as on the Mac (CameraRecorder.withScreen).
pub fn camera_too() -> bool {
    load().get("cameraWithScreen").and_then(Value::as_bool).unwrap_or(false)
}

/// "Record Vertical": new recordings open in the vertical layout, remembered
/// as on the Mac (RecordLayout, the `recordVertical` default).
pub fn vertical() -> bool {
    load().get("recordVertical").and_then(Value::as_bool).unwrap_or(false)
}

pub fn save_vertical(on: bool) {
    let mut m = load();
    m.insert("recordVertical".into(), Value::Bool(on));
    save(&m);
}

pub fn save_camera_too(on: bool) {
    let mut m = load();
    m.insert("cameraWithScreen".into(), Value::Bool(on));
    save(&m);
}
