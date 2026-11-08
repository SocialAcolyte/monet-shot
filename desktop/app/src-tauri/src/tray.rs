//! The tray item. Linux and Windows trays show an icon only (no text), so
//! the state is drawn into the icon: the ring at rest, the 3-2-1 as the
//! Mac's charcoal pill, the clay ring while recording. Where a tray can carry
//! a label (macOS, Linux AppIndicator) the time sits beside it as on the Mac;
//! the pill window shows it everywhere.

use std::sync::Mutex;

use tauri::image::Image;
use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::tray::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, Wry};
use tiny_skia::{Color, FillRule, LineCap, Paint, PathBuilder, Pixmap, Stroke, Transform};

use crate::bar::{self, Bar, BarState, Phase};
use crate::{library, windows};

const TRAY_ID: &str = "monetshot";

// Palette (Sources/MonetShot/UI/Motion.swift).
const MOON_WHITE: (u8, u8, u8) = (0xE6, 0xE3, 0xDD);
const CLAY: (u8, u8, u8) = (0xC9, 0x6F, 0x4A);
const CHARCOAL: (u8, u8, u8) = (0x17, 0x19, 0x1B);

/// What the icon shows; redrawn only when this changes.
#[derive(Clone, Copy, PartialEq, Debug)]
enum Look {
    Idle { busy: bool },
    Countdown(u8),
    Recording { paused: bool },
}

struct TrayState {
    look: Option<Look>,
    title: Option<String>,
    menu_key: Option<(bool, bool, bool, bool, Vec<std::path::PathBuf>)>,
}

static STATE: Mutex<TrayState> = Mutex::new(TrayState { look: None, title: None, menu_key: None });

fn look(s: &BarState) -> Look {
    match s.phase {
        Phase::Countdown { n } => Look::Countdown(n),
        Phase::Recording { .. } => Look::Recording { paused: s.paused },
        Phase::Saving => Look::Recording { paused: false },
        Phase::Picking | Phase::Starting => Look::Idle { busy: true },
        Phase::Idle => Look::Idle { busy: false },
    }
}

pub fn create(app: &AppHandle) -> tauri::Result<()> {
    let snap = app.state::<Bar>().snapshot();
    let tray = TrayIconBuilder::with_id(TRAY_ID)
        .icon(render(look(&snap)))
        .icon_as_template(cfg!(target_os = "macos"))
        .tooltip("Monet Shot")
        .menu(&build_menu(app, &snap)?)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, e| on_menu(app, e.id().as_ref()))
        .on_tray_icon_event(|tray, e| {
            // A left click on the ring records, as on the Mac. (Linux trays
            // send no clicks; their menu has Record….)
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = e {
                let app = tray.app_handle();
                app.state::<Bar>().tap(app);
            }
        })
        .build(app)?;
    STATE.lock().unwrap().look = Some(look(&snap));
    let _ = tray;
    // The clock beside/inside the item, once a second while recording.
    let app = app.clone();
    // Waybar's status gets the same second.
    std::thread::spawn(move || {
        let mut second = None;
        loop {
            std::thread::sleep(std::time::Duration::from_millis(250));
            let bar = app.state::<Bar>();
            let snap = bar.snapshot();
            set_title(&app, &snap);
            let now = matches!(snap.phase, Phase::Recording { .. }).then(|| bar.elapsed() as u64);
            if now.is_some() && now != second {
                bar.publish();
            }
            second = now;
        }
    });
    Ok(())
}

fn tray(app: &AppHandle) -> Option<TrayIcon<Wry>> {
    app.tray_by_id(TRAY_ID)
}

/// Called on every state change.
pub fn update(app: &AppHandle, s: &BarState) {
    let Some(tray) = tray(app) else { return };
    let l = look(s);
    let changed = {
        let mut st = STATE.lock().unwrap();
        let c = st.look != Some(l);
        st.look = Some(l);
        c
    };
    if changed {
        let _ = tray.set_icon(Some(render(l)));
        // Only the resting ring takes the menu bar's own ink on macOS.
        let _ = tray.set_icon_as_template(cfg!(target_os = "macos") && matches!(l, Look::Idle { .. }));
    }
    set_title(app, s);
    refresh_menu(app);
}

fn set_title(app: &AppHandle, s: &BarState) {
    let text = match s.phase {
        Phase::Recording { .. } => Some(bar::clock(app.state::<Bar>().elapsed())),
        Phase::Saving => Some("Saving".to_string()),
        _ => s.problem.clone(),
    };
    {
        let mut st = STATE.lock().unwrap();
        if st.title == text {
            return;
        }
        st.title = text.clone();
    }
    let Some(tray) = tray(app) else { return };
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    let _ = tray.set_title(text.as_deref());
    let tip = match &text {
        Some(t) => format!("Monet Shot — {t}"),
        None => "Monet Shot".to_string(),
    };
    let _ = tray.set_tooltip(Some(tip));
}

/// Rebuilds the menu when what it lists has changed.
pub fn refresh_menu(app: &AppHandle) {
    let snap = app.state::<Bar>().snapshot();
    let recording = matches!(snap.phase, Phase::Recording { .. });
    let key = (recording, snap.paused, snap.camera_too, snap.vertical, library::recent(6));
    {
        let mut st = STATE.lock().unwrap();
        if st.menu_key.as_ref() == Some(&key) {
            return;
        }
        st.menu_key = Some(key);
    }
    if let (Some(tray), Ok(menu)) = (tray(app), build_menu(app, &snap)) {
        let _ = tray.set_menu(Some(menu));
    }
}

fn reveal_label() -> &'static str {
    if cfg!(target_os = "macos") {
        "Show Recordings in Finder"
    } else if cfg!(target_os = "windows") {
        "Show Recordings in Explorer"
    } else {
        "Show Recordings in Files"
    }
}

fn build_menu(app: &AppHandle, s: &BarState) -> tauri::Result<Menu<Wry>> {
    let menu = Menu::new(app)?;
    if matches!(s.phase, Phase::Recording { .. }) {
        menu.append(&MenuItem::with_id(app, "pause", if s.paused { "Resume" } else { "Pause" }, true, None::<&str>)?)?;
        menu.append(&MenuItem::with_id(app, "hint", "Double-tap Shift to pause or resume", false, None::<&str>)?)?;
        menu.append(&MenuItem::with_id(app, "stop", "Stop Recording", true, None::<&str>)?)?;
    } else {
        menu.append(&MenuItem::with_id(app, "record", "Record…", true, None::<&str>)?)?;
        if crate::recorder::remembers_pick() {
            menu.append(&MenuItem::with_id(app, "choose", "Choose what to record…", true, None::<&str>)?)?;
        }
        menu.append(&CheckMenuItem::with_id(app, "camera", "Record My Camera Too", true, s.camera_too, None::<&str>)?)?;
        menu.append(&CheckMenuItem::with_id(app, "vertical", "Record Vertical", true, s.vertical, None::<&str>)?)?;
        menu.append(&mic_menu(app)?)?;
    }
    menu.append(&MenuItem::with_id(app, "home", "Open Monet Shot", true, Some("CmdOrCtrl+O"))?)?;
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    let recent = library::recent(6);
    if !recent.is_empty() {
        menu.append(&MenuItem::with_id(app, "recent-header", "Recent", false, None::<&str>)?)?;
        for (i, url) in recent.iter().enumerate() {
            menu.append(&MenuItem::with_id(app, format!("recent-{i}"), library::title(url), true, None::<&str>)?)?;
        }
        menu.append(&PredefinedMenuItem::separator(app)?)?;
    }
    menu.append(&MenuItem::with_id(app, "open", "Open Recording…", true, None::<&str>)?)?;
    menu.append(&MenuItem::with_id(app, "reveal", reveal_label(), true, None::<&str>)?)?;
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    menu.append(&MenuItem::with_id(app, "quit", "Quit Monet Shot", true, Some("CmdOrCtrl+Q"))?)?;
    Ok(menu)
}

/// "Microphone": off, or which one records your voice with the screen.
fn mic_menu(app: &AppHandle) -> tauri::Result<Submenu<Wry>> {
    let chosen = crate::speech::settings().mic;
    let sub = Submenu::with_id(app, "mic", "Microphone", true)?;
    sub.append(&CheckMenuItem::with_id(app, "mic:", "Off", true, chosen.is_none(), None::<&str>)?)?;
    for m in mics() {
        let on = chosen.as_deref() == Some(m.id.as_str());
        sub.append(&CheckMenuItem::with_id(app, format!("mic:{}", m.id), &m.name, true, on, None::<&str>)?)?;
    }
    Ok(sub)
}

/// The microphones, listed once (listing runs ffmpeg or pactl).
fn mics() -> Vec<monetshot_capture::Device> {
    static LIST: std::sync::OnceLock<Vec<monetshot_capture::Device>> = std::sync::OnceLock::new();
    LIST.get_or_init(|| {
        let mut v = monetshot_capture::microphones().unwrap_or_default();
        if !v.iter().any(|d| d.id == "default") {
            v.insert(0, monetshot_capture::Device { id: "default".into(), name: "Default microphone".into() });
        }
        v
    })
    .clone()
}

fn on_menu(app: &AppHandle, id: &str) {
    let bar = app.state::<Bar>();
    if let Some(mic) = id.strip_prefix("mic:") {
        let mut s = crate::speech::settings();
        s.mic = (!mic.is_empty()).then(|| mic.to_string());
        if let Err(e) = crate::speech::speech_set(s) {
            crate::log::error(&format!("microphone choice: {e}"));
        }
        STATE.lock().unwrap().menu_key = None;
        refresh_menu(app);
        return;
    }
    match id {
        "record" => bar.tap(app),
        "choose" => {
            crate::recorder::forget_pick();
            bar.tap(app);
        }
        "camera" => bar.toggle_camera_too(app),
        "vertical" => bar.toggle_vertical(app),
        "pause" => bar.toggle_pause(app),
        "stop" => bar.stop(app),
        "home" => windows::show_home(app),
        "open" => windows::open_recording_dialog(app),
        "reveal" => windows::reveal_library(app),
        "quit" => crate::quit(app),
        _ => {
            if let Some(i) = id.strip_prefix("recent-").and_then(|n| n.parse::<usize>().ok()) {
                if let Some(url) = library::recent(6).get(i) {
                    windows::open_editor(app, url);
                }
            }
        }
    }
}

// MARK: drawing

/// Icons are drawn on a 22-point canvas (the Mac's bar height) around the
/// Mac's 16-point aperture, at 2x.
const SCALE: f32 = 2.0;
const CANVAS: f32 = 22.0;

fn color((r, g, b): (u8, u8, u8), alpha: f32) -> Color {
    Color::from_rgba8(r, g, b, (alpha * 255.0).round() as u8)
}

fn paint(c: Color) -> Paint<'static> {
    let mut p = Paint::default();
    p.set_color(c);
    p.anti_alias = true;
    p
}

fn render(l: Look) -> Image<'static> {
    let px = (CANVAS * SCALE) as u32;
    let mut pm = Pixmap::new(px, px).expect("icon pixmap");
    let t = Transform::from_scale(SCALE, SCALE);
    match l {
        Look::Idle { busy } => {
            // Template on macOS: black, the bar tints it. Elsewhere moon white.
            let ink = if cfg!(target_os = "macos") { (0, 0, 0) } else { MOON_WHITE };
            aperture(&mut pm, t, color(ink, if busy { 0.5 } else { 0.9 }), 5.0, 1.0);
        }
        Look::Recording { paused } => {
            // Paused, the pupil shrinks back to a dot: the take is waiting.
            let c = color(CLAY, 1.0);
            aperture(&mut pm, t, c, if paused { 5.0 } else { 3.2 }, if paused { 0.55 } else { 1.0 });
        }
        Look::Countdown(n) => {
            // The Mac's Pill: charcoal 0.92, radius 7, 19 high, min 22 wide.
            let pill = rounded_rect(0.0, 1.5, 22.0, 19.0, 7.0);
            pm.fill_path(&pill, &paint(color(CHARCOAL, 0.92)), FillRule::Winding, t, None);
            if let Some(d) = digit(n) {
                // A 6x9 digit, centred.
                let dt = t.pre_translate(8.0, 6.5);
                let stroke = Stroke { width: 1.7, line_cap: LineCap::Round, ..Stroke::default() };
                pm.stroke_path(&d, &paint(color(MOON_WHITE, 1.0)), &stroke, dt, None);
            }
        }
    }
    Image::new_owned(pm.data().to_vec(), px, px)
}

/// The mark: a 16-point ring (1.5 stroke inside its bounds) with a pupil
/// inset by `inset`, centred on the canvas.
fn aperture(pm: &mut Pixmap, t: Transform, c: Color, inset: f32, pupil_alpha: f32) {
    let (cx, cy) = (CANVAS / 2.0, CANVAS / 2.0);
    if let Some(ring) = PathBuilder::from_circle(cx, cy, 8.0 - 0.75) {
        pm.stroke_path(&ring, &paint(c), &Stroke { width: 1.5, ..Stroke::default() }, t, None);
    }
    if let Some(dot) = PathBuilder::from_circle(cx, cy, 8.0 - inset) {
        let mut pc = c;
        pc.apply_opacity(pupil_alpha);
        pm.fill_path(&dot, &paint(pc), FillRule::Winding, t, None);
    }
}

fn rounded_rect(x: f32, y: f32, w: f32, h: f32, r: f32) -> tiny_skia::Path {
    let k = 0.5523 * r;
    let mut pb = PathBuilder::new();
    pb.move_to(x + r, y);
    pb.line_to(x + w - r, y);
    pb.cubic_to(x + w - r + k, y, x + w, y + r - k, x + w, y + r);
    pb.line_to(x + w, y + h - r);
    pb.cubic_to(x + w, y + h - r + k, x + w - r + k, y + h, x + w - r, y + h);
    pb.line_to(x + r, y + h);
    pb.cubic_to(x + r - k, y + h, x, y + h - r + k, x, y + h - r);
    pb.line_to(x, y + r);
    pb.cubic_to(x, y + r - k, x + r - k, y, x + r, y);
    pb.close();
    pb.finish().expect("rounded rect")
}

/// The countdown's digits as strokes in a 6x9 box (there's no font in a tray).
fn digit(n: u8) -> Option<tiny_skia::Path> {
    let mut pb = PathBuilder::new();
    match n {
        1 => {
            pb.move_to(1.4, 2.0);
            pb.line_to(3.6, 0.3);
            pb.line_to(3.6, 8.7);
        }
        2 => {
            pb.move_to(0.8, 2.6);
            pb.cubic_to(0.8, 1.2, 1.9, 0.3, 3.1, 0.3);
            pb.cubic_to(4.4, 0.3, 5.3, 1.2, 5.3, 2.5);
            pb.cubic_to(5.3, 3.6, 4.6, 4.4, 3.6, 5.3);
            pb.line_to(0.7, 8.7);
            pb.line_to(5.4, 8.7);
        }
        3 => {
            pb.move_to(0.9, 1.6);
            pb.cubic_to(1.4, 0.7, 2.2, 0.3, 3.1, 0.3);
            pb.cubic_to(4.4, 0.3, 5.2, 1.1, 5.2, 2.3);
            pb.cubic_to(5.2, 3.5, 4.3, 4.3, 2.8, 4.3);
            pb.cubic_to(4.5, 4.3, 5.5, 5.2, 5.5, 6.5);
            pb.cubic_to(5.5, 7.8, 4.5, 8.7, 3.1, 8.7);
            pb.cubic_to(2.0, 8.7, 1.1, 8.2, 0.7, 7.3);
        }
        _ => return None,
    }
    pb.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Writes every look to PNGs for eyeballing: `cargo test tray_sheet -- --ignored`.
    #[test]
    #[ignore]
    fn tray_sheet() {
        let dir = std::env::temp_dir().join("monetshot-tray");
        std::fs::create_dir_all(&dir).unwrap();
        let looks = [
            ("idle", Look::Idle { busy: false }),
            ("busy", Look::Idle { busy: true }),
            ("3", Look::Countdown(3)),
            ("2", Look::Countdown(2)),
            ("1", Look::Countdown(1)),
            ("rec", Look::Recording { paused: false }),
            ("paused", Look::Recording { paused: true }),
        ];
        for (name, l) in looks {
            let img = render(l);
            let pm = Pixmap::from_vec(
                img.rgba().to_vec(),
                tiny_skia::IntSize::from_wh(img.width(), img.height()).unwrap(),
            )
            .unwrap();
            pm.save_png(dir.join(format!("{name}.png"))).unwrap();
        }
        eprintln!("{}", dir.display());
    }
}
