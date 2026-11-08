//! Monet Shot for Linux and Windows (and macOS for development): a tray
//! item that records, Home, and one editor window per recording.

mod bar;
mod camera;
mod commands;
mod editor;
mod home;
mod library;
mod log;
mod media;
mod recorder;
mod settings;
mod speech;
mod tray;
mod windows;

use std::sync::atomic::{AtomicBool, Ordering};

use tauri::{AppHandle, Manager, RunEvent};

static QUITTING: AtomicBool = AtomicBool::new(false);

/// Quit Monet Shot: the only way out (closing windows leaves the tray).
pub fn quit(app: &AppHandle) {
    QUITTING.store(true, Ordering::SeqCst);
    recorder::stop_blocking();
    monetshot_capture::status::clear();
    app.exit(0);
}

/// `monet-shot toggle` / `monet-shot pause`, from this process's own
/// arguments or forwarded from a second launch.
fn command(app: &AppHandle, args: &[String]) {
    let bar = app.state::<bar::Bar>();
    match args.get(1).map(String::as_str) {
        Some("toggle") => bar.toggle_from_cli(app),
        Some("pause") => bar.toggle_pause(app),
        // A recording opened from the file manager (or the command line).
        Some(path) if std::path::Path::new(path).join("meta.json").exists() => windows::open_editor(app, std::path::Path::new(path)),
        // Launched again by hand: show the recordings.
        _ => windows::show_home(app),
    }
}

/// `monet-shot --aspect <rec.reel> landscape|vertical|square`, `--vertical
/// <rec.reel>`, `--render <rec.reel> <out.mp4>`: as the Mac's `MonetShot`
/// flags, without starting the app. Exits with 0 when it worked.
fn edit_cli(args: &[String]) -> Option<i32> {
    use monetshot_core::{CanvasLayout, Project};
    let flag = args.get(1)?.as_str();
    let run = |work: &dyn Fn() -> Result<String, String>| match work() {
        Ok(out) => {
            println!("{out}");
            0
        }
        Err(e) => {
            eprintln!("error: {e}");
            1
        }
    };
    match (flag, args.len()) {
        ("--aspect", 4) | ("--vertical", 3) => Some(run(&|| {
            let name = if flag == "--vertical" { "vertical" } else { args[3].as_str() };
            let layout = CanvasLayout::parse(name);
            if matches!(layout, CanvasLayout::Other(_)) {
                return Err(format!("no layout \"{name}\"; try landscape, vertical, square"));
            }
            let folder = std::path::Path::new(&args[2]);
            let mut p = Project::load(folder).map_err(|e| e.to_string())?;
            p.edit.set_layout(layout.clone());
            p.save_edit().map_err(|e| e.to_string())?;
            let (w, h) = p.edit.canvas_size(p.meta().aspect());
            Ok(format!("{}: {w}x{h}", layout.label()))
        })),
        ("--render", 4) => Some(run(&|| {
            let p = Project::load(std::path::Path::new(&args[2])).map_err(|e| e.to_string())?;
            let out = std::path::PathBuf::from(&args[3]);
            let t0 = std::time::Instant::now();
            monetshot_export::export(&p, &out, &|_| {}, &std::sync::atomic::AtomicBool::new(false)).map_err(|e| e.to_string())?;
            Ok(format!("exported {} in {:.1}s", out.display(), t0.elapsed().as_secs_f64()))
        })),
        ("--aspect" | "--vertical" | "--render", _) => {
            eprintln!("usage: monet-shot --aspect <rec.reel> <landscape|vertical|square>\n       monet-shot --vertical <rec.reel>\n       monet-shot --render <rec.reel> <out.mp4>");
            Some(2)
        }
        _ => None,
    }
}

/// Runs a command that needs no app (`status`, the edit flags); true when it did.
pub fn run_cli() -> bool {
    let args: Vec<String> = std::env::args().collect();
    if let Some(code) = edit_cli(&args) {
        std::process::exit(code);
    }
    if args.get(1).map(String::as_str) != Some("status") {
        return false;
    }
    use monetshot_capture::status;
    if args.iter().any(|a| a == "--follow") {
        status::follow(|s| {
            println!("{}", status::waybar_json(s));
            true
        });
    } else if args.iter().any(|a| a == "--waybar") {
        println!("{}", status::waybar_json(status::read().as_ref()));
    } else {
        println!("{}", serde_json::to_string(&status::read()).unwrap_or_default());
    }
    true
}

pub fn run() {
    if run_cli() {
        return;
    }
    log::install();
    let app = tauri::Builder::default()
        // One Monet Shot: a second launch hands its arguments to this one.
        .plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| command(app, &argv)))
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .manage(bar::Bar::new(settings::camera_too(), settings::vertical()))
        // A closed window's media URLs stop working (media.rs).
        .on_window_event(|w, e| {
            if let tauri::WindowEvent::Destroyed = e {
                media::release(w.label());
            }
        })
        .invoke_handler(tauri::generate_handler![
            commands::bar_state,
            commands::bar_tap,
            commands::bar_cancel,
            commands::bar_toggle_pause,
            commands::bar_toggle_vertical,
            commands::bar_stop,
            commands::show_home,
            commands::picker_sources,
            commands::picker_choose,
            commands::camera_preview,
            commands::home_items,
            commands::home_thumb,
            commands::open_recording,
            commands::reveal,
            commands::trash,
            commands::import_video,
            commands::editor_load,
            commands::editor_save,
            commands::record_take,
            commands::filmstrip,
            commands::backdrop_gallery,
            commands::backdrop_copy,
            commands::recording_remove_file,
            commands::add_footage,
            commands::export_start,
            commands::ui_log,
            speech::speech_settings,
            speech::speech_set,
            speech::microphones,
            speech::transcribe,
            speech::transcribe_cancel,
            speech::transcript_save,
            media::camera_open,
            media::camera_close,
            media::camera_devices,
            media::camera_use,
            media::camera_record,
            media::camera_stop,
            media::camera_take,
            media::music_library,
            media::music_own_file,
            media::music_add,
            media::music_shape,
            media::music_suggest,
            media::music_voice,
            media::video_proxy,
            media::media_url,
            media::media_release,
        ])
        .setup(|app| {
            log::info("launched");
            let handle = app.handle().clone();
            tray::create(&handle)?;
            app.state::<bar::Bar>().publish();
            let args: Vec<String> = std::env::args().collect();
            if args.len() > 1 {
                command(&handle, &args);
            } else {
                // Launched by hand: show the recordings, as the Mac does.
                windows::show_home(&handle);
            }
            // Developer aid: MONETSHOT_DEV_PAGE=fixtures-test.html opens a dev page
            // (from the Vite server) in a window; its results go to the log.
            if let Ok(page) = std::env::var("MONETSHOT_DEV_PAGE") {
                let _ = tauri::WebviewWindowBuilder::new(app, "devpage", tauri::WebviewUrl::App(page.into()))
                    .title("Monet Shot dev page")
                    .inner_size(1100.0, 800.0)
                    .build();
            }
            // Developer aid: MONETSHOT_DEMO_RECORD=1 clicks the ring a second after launch.
            if std::env::var_os("MONETSHOT_DEMO_RECORD").is_some() {
                let h = handle.clone();
                std::thread::spawn(move || {
                    std::thread::sleep(std::time::Duration::from_secs(1));
                    h.state::<bar::Bar>().tap(&h);
                });
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("building Monet Shot");

    app.run(|_app, e| {
        // Closing the last window leaves the tray running.
        if let RunEvent::ExitRequested { api, code, .. } = e {
            if code.is_none() && !QUITTING.load(Ordering::SeqCst) {
                api.prevent_exit();
            }
        }
    });
}
