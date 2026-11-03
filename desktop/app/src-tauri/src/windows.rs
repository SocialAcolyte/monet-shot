//! Every window the app owns: Home, one editor per recording, and the pill
//! (the 3-2-1, time, pause and hold-to-stop that the Mac draws in its menu
//! bar; trays elsewhere can't hold controls).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder};
#[cfg(target_os = "linux")]
use tauri::Emitter;
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_opener::OpenerExt;

use crate::bar::{BarState, Phase};
use crate::{library, log};
use monetshot_core::paths;

pub const HOME: &str = "home";
pub const PILL: &str = "pill";
pub const PICKER: &str = "picker";
pub const BUBBLE: &str = "bubble";

/// Charcoal, so a window never flashes white before the page paints.
const CHARCOAL: tauri::window::Color = tauri::window::Color(0x17, 0x19, 0x1B, 0xFF);

struct Registry {
    /// Recording folder -> editor window label.
    editors: HashMap<PathBuf, String>,
    next: u32,
    /// Windows put away for a recording, to bring back after it.
    hidden: Vec<String>,
}

static REG: Mutex<Option<Registry>> = Mutex::new(None);

fn with_reg<T>(f: impl FnOnce(&mut Registry) -> T) -> T {
    let mut g = REG.lock().unwrap();
    f(g.get_or_insert_with(|| Registry { editors: HashMap::new(), next: 1, hidden: vec![] }))
}

fn url(view: &str, query: &[(&str, &str)]) -> WebviewUrl {
    let mut s = format!("index.html?view={view}");
    // Developer aid: MONETSHOT_DEV_SCRIPT=<abs path to .js> runs in every
    // page of a dev build (checks that drive the UI and log what they see).
    if let Ok(script) = std::env::var("MONETSHOT_DEV_SCRIPT") {
        s.push_str("&devscript=");
        s.push_str(&encode(&script));
    }
    for (k, v) in query {
        s.push('&');
        s.push_str(k);
        s.push('=');
        s.push_str(&encode(v));
    }
    WebviewUrl::App(s.into())
}

fn encode(v: &str) -> String {
    v.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// The Mac's window look: dark, title bar transparent over the content.
fn styled<'a>(b: WebviewWindowBuilder<'a, tauri::Wry, AppHandle>, title: &str) -> WebviewWindowBuilder<'a, tauri::Wry, AppHandle> {
    let b = b.title(title).background_color(CHARCOAL).theme(Some(tauri::Theme::Dark));
    #[cfg(target_os = "macos")]
    let b = b.title_bar_style(tauri::TitleBarStyle::Overlay).hidden_title(true);
    b
}

pub fn show_home(app: &AppHandle) {
    if let Some(w) = app.get_webview_window(HOME) {
        let _ = w.unminimize();
        let _ = w.show();
        let _ = w.set_focus();
        return;
    }
    let b = WebviewWindowBuilder::new(app, HOME, url("home", &[]))
        .inner_size(980.0, 680.0)
        .min_inner_size(620.0, 440.0)
        .center();
    if let Err(e) = styled(b, "Monet Shot").build() {
        log::error(&format!("home window: {e}"));
    }
}

/// `fs::canonicalize`, without the verbatim prefix it adds on Windows
/// (`\\?\D:\…`): the editor shows this path, exports next to it and hands it
/// to Explorer, which all want the ordinary form.
fn canonical(folder: &Path) -> PathBuf {
    let c = std::fs::canonicalize(folder).unwrap_or_else(|_| folder.to_path_buf());
    #[cfg(windows)]
    if let Some(plain) = c.to_str().and_then(|s| s.strip_prefix(r"\\?\")) {
        // Only drive paths: \\?\UNC\… has no plain form this simple.
        if plain.as_bytes().get(1) == Some(&b':') {
            return PathBuf::from(plain);
        }
    }
    c
}

pub fn open_editor(app: &AppHandle, folder: &Path) {
    let key = canonical(folder);
    if let Some(label) = with_reg(|r| r.editors.get(&key).cloned()) {
        if let Some(w) = app.get_webview_window(&label) {
            let _ = w.unminimize();
            let _ = w.show();
            let _ = w.set_focus();
            return;
        }
    }
    let label = with_reg(|r| {
        let l = format!("editor-{}", r.next);
        r.next += 1;
        r.editors.insert(key.clone(), l.clone());
        l
    });
    let path = key.to_string_lossy().to_string();
    let mut query = vec![("reel".to_string(), path)];
    // Developer aids, as the Mac's: MONETSHOT_SNAPSHOT_TIME=<s>,
    // MONETSHOT_SNAPSHOT_SELECT=<zoom index>, MONETSHOT_SNAPSHOT_CLIP=<clip index>,
    // MONETSHOT_SNAPSHOT_FRAMING=blur|crop, MONETSHOT_SNAPSHOT_MUSIC=1 (the browser),
    // MONETSHOT_SNAPSHOT_SCROLL=bottom (the inspector's last sections),
    // MONETSHOT_SNAPSHOT_EXPORT=1 (presses Export).
    for (env, k) in [("MONETSHOT_SNAPSHOT_TIME", "t"), ("MONETSHOT_SNAPSHOT_SELECT", "select"), ("MONETSHOT_SNAPSHOT_CLIP", "clip"), ("MONETSHOT_SNAPSHOT_FRAMING", "framing"), ("MONETSHOT_SNAPSHOT_MUSIC", "music"), ("MONETSHOT_SNAPSHOT_SCROLL", "scroll"), ("MONETSHOT_SNAPSHOT_EXPORT", "export")] {
        if let Ok(v) = std::env::var(env) {
            query.push((k.to_string(), v));
        }
    }
    let q: Vec<(&str, &str)> = query.iter().map(|(a, b)| (a.as_str(), b.as_str())).collect();
    let b = WebviewWindowBuilder::new(app, &label, url("editor", &q))
        .inner_size(1320.0, 860.0)
        .min_inner_size(980.0, 640.0)
        .center();
    let built = styled(b, &library::title(&key)).build();
    match built {
        Ok(w) => {
            w.on_window_event(move |e| {
                if let tauri::WindowEvent::Destroyed = e {
                    with_reg(|r| r.editors.retain(|_, l| *l != label));
                }
            });
        }
        Err(e) => log::error(&format!("editor window: {e}")),
    }
}

/// Editors and Home step out of the way while the screen is recorded.
pub fn hide_for_recording(app: &AppHandle, hide: bool) {
    if hide {
        let shown: Vec<WebviewWindow> = app
            .webview_windows()
            .into_values()
            .filter(|w| w.label() != PILL && w.label() != BUBBLE && w.is_visible().unwrap_or(false))
            .collect();
        for w in &shown {
            let _ = w.hide();
        }
        with_reg(|r| r.hidden.extend(shown.iter().map(|w| w.label().to_string())));
    } else {
        for l in with_reg(|r| std::mem::take(&mut r.hidden)) {
            if let Some(w) = app.get_webview_window(&l) {
                let _ = w.show();
            }
        }
    }
}

/// The pill shows whenever the Mac's bar item would show more than its ring.
pub fn pill_follow(app: &AppHandle, s: &BarState) {
    let recording = matches!(s.phase, Phase::Recording { .. });
    // On Linux with a bar showing our clock (Waybar, omarchy-shell), the pill
    // stays away while recording: Hyprland can only black it out of the
    // capture, and the bar already shows the time, stops and pauses.
    let want = (s.phase != Phase::Idle || s.problem.is_some()) && !(recording && bar_shows_us());
    let app2 = app.clone();
    let _ = app.run_on_main_thread(move || {
        let w = match app2.get_webview_window(PILL) {
            Some(w) => w,
            None if want => match make_pill(&app2) {
                Some(w) => w,
                None => return,
            },
            None => return,
        };
        if want {
            let _ = w.show();
            // GTK (X11 without Hyprland rules) drops the size and position
            // of a window that was hidden when they were set: set them again
            // once it's mapped. The page re-fits its width after this.
            #[cfg(target_os = "linux")]
            {
                let (x, y) = pill_origin(&app2);
                let _ = w.set_position(tauri::LogicalPosition::new(x, y));
                let _ = w.set_size(tauri::LogicalSize::new(180.0, 34.0));
                let _ = app2.emit_to(PILL, "pill-refit", ());
            }
        } else {
            let _ = w.hide();
        }
    });
}

/// A status bar runs our module (Linux only; checked once).
fn bar_shows_us() -> bool {
    #[cfg(target_os = "linux")]
    {
        static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
        *ON.get_or_init(|| {
            let on_path = |name: &str| {
                std::env::var_os("PATH")
                    .is_some_and(|p| std::env::split_paths(&p).any(|d| d.join(name).is_file()))
            };
            let running = |name: &str| {
                std::fs::read_dir("/proc").ok().is_some_and(|rd| {
                    rd.filter_map(|e| e.ok()).any(|e| {
                        std::fs::read_to_string(e.path().join("comm")).is_ok_and(|c| c.trim() == name)
                    })
                })
            };
            on_path("omarchy-shell") || running("waybar")
        })
    }
    #[cfg(not(target_os = "linux"))]
    false
}

/// Top centre of the main screen, under where a bar would be.
fn pill_origin(app: &AppHandle) -> (f64, f64) {
    app.primary_monitor()
        .ok()
        .flatten()
        .map(|m| {
            let s = m.scale_factor();
            let size = m.size().to_logical::<f64>(s);
            let pos = m.position().to_logical::<f64>(s);
            (pos.x + size.width / 2.0 - 90.0, pos.y + 34.0)
        })
        .unwrap_or((400.0, 34.0))
}

fn make_pill(app: &AppHandle) -> Option<WebviewWindow> {
    let (x, y) = pill_origin(app);
    // The title is what Hyprland rules match (float, pin, no animation).
    let b = WebviewWindowBuilder::new(app, PILL, url("pill", &[]))
        .title("Monet Shot Pill")
        .inner_size(180.0, 34.0)
        .position(x, y)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .resizable(false)
        .always_on_top(true)
        .visible_on_all_workspaces(true)
        .skip_taskbar(true)
        .focused(false)
        // Kept out of the recording where the OS allows (Windows, macOS);
        // the demo aid leaves it visible to screenshots, unless
        // MONETSHOT_DEMO_PROTECT=1 (CI checks the pill stays out of a take).
        .content_protected(std::env::var_os("MONETSHOT_DEMO_RECORD").is_none() || std::env::var_os("MONETSHOT_DEMO_PROTECT").is_some())
        .visible(false);
    match b.build() {
        Ok(w) => Some(w),
        Err(e) => {
            log::error(&format!("pill window: {e}"));
            None
        }
    }
}

/// A round window of you in the screen's corner while the 3-2-1 counts in a
/// recording with the camera, so you can check your hair. It goes when
/// recording starts: the recording would see it (CameraBubble).
pub fn show_bubble(app: &AppHandle) {
    let app2 = app.clone();
    let _ = app.run_on_main_thread(move || {
        if app2.get_webview_window(BUBBLE).is_some() {
            return;
        }
        let size = 200.0;
        let (x, y) = app2
            .primary_monitor()
            .ok()
            .flatten()
            .map(|m| {
                let s = m.scale_factor();
                let wa = m.work_area();
                let pos = wa.position.to_logical::<f64>(s);
                let sz = wa.size.to_logical::<f64>(s);
                (pos.x + sz.width - size - 28.0, pos.y + sz.height - size - 28.0)
            })
            .unwrap_or((40.0, 40.0));
        let b = WebviewWindowBuilder::new(&app2, BUBBLE, url("bubble", &[]))
            .title("Monet Shot Camera")
            .inner_size(size, size)
            .position(x, y)
            .decorations(false)
            .transparent(true)
            .shadow(false)
            .resizable(false)
            .always_on_top(true)
            .visible_on_all_workspaces(true)
            .skip_taskbar(true)
            .focused(false);
        match b.build() {
            Ok(w) => {
                let _ = w.set_ignore_cursor_events(true);
            }
            Err(e) => log::error(&format!("bubble window: {e}")),
        }
    });
}

pub fn hide_bubble(app: &AppHandle) {
    let app2 = app.clone();
    let _ = app.run_on_main_thread(move || {
        if let Some(w) = app2.get_webview_window(BUBBLE) {
            let _ = w.destroy();
        }
    });
}

/// Our own picker (Windows, macos-dev; Linux uses the portal's).
pub fn show_picker(app: &AppHandle) {
    let app2 = app.clone();
    let _ = app.run_on_main_thread(move || {
        if let Some(w) = app2.get_webview_window(PICKER) {
            let _ = w.show();
            let _ = w.set_focus();
            return;
        }
        let b = WebviewWindowBuilder::new(&app2, PICKER, url("picker", &[]))
            .inner_size(760.0, 520.0)
            .min_inner_size(520.0, 360.0)
            .always_on_top(true)
            .center();
        match styled(b, "Monet Shot Picker").build() {
            Ok(w) => {
                // Closing the window is choosing nothing.
                let app3 = app2.clone();
                w.on_window_event(move |e| {
                    if let tauri::WindowEvent::CloseRequested { .. } = e {
                        crate::recorder::choose(&app3, None);
                    }
                });
            }
            Err(e) => log::error(&format!("picker window: {e}")),
        }
    });
}

pub fn close_picker(app: &AppHandle) {
    let app2 = app.clone();
    let _ = app.run_on_main_thread(move || {
        if let Some(w) = app2.get_webview_window(PICKER) {
            let _ = w.destroy();
        }
    });
}

pub fn open_recording_dialog(app: &AppHandle) {
    let app2 = app.clone();
    app.dialog()
        .file()
        .set_title("Choose a .reel recording")
        .set_directory(paths::library_dir())
        .pick_folder(move |f| {
            if let Some(p) = f.and_then(|f| f.into_path().ok()) {
                open_editor(&app2, &p);
            }
        });
}

pub fn reveal_library(app: &AppHandle) {
    let dir = paths::library_dir();
    let _ = std::fs::create_dir_all(&dir);
    if let Err(e) = app.opener().open_path(dir.to_string_lossy(), None::<&str>) {
        log::error(&format!("reveal library: {e}"));
    }
}
