//! Records a few seconds of the first source with a pause in the middle,
//! then checks the take folder opens. `cargo run -p monetshot-capture
//! --example record -- [seconds] [library dir] [--camera]`
use std::sync::Arc;
use std::time::Duration;

use monetshot_capture::{backend, CameraChoice, Event, StartOptions};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let secs: f64 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(4.0);
    let lib = args.get(2).filter(|a| !a.starts_with("--")).cloned().unwrap_or_else(|| std::env::temp_dir().join("monetshot-example").display().to_string());
    let b = backend();
    println!("backend: {} {:?}", b.name(), b.capabilities());
    let picked = if b.capabilities().system_picker {
        b.pick().expect("pick").expect("cancelled")
    } else {
        let sources = b.list_sources(true).expect("sources");
        for s in &sources {
            println!("source: {:?} {} {:?} thumb={:?}", s.kind, s.title, s.bounds, s.thumbnail.as_ref().map(|t| (t.width, t.height)));
        }
        b.choose(&sources[0].id).expect("choose")
    };
    let mut opts = StartOptions::new(&lib);
    if args.iter().any(|a| a == "--camera") {
        opts.camera = Some(CameraChoice::default());
    }
    let (tx, rx) = std::sync::mpsc::channel();
    let sink = Arc::new(move |e: Event| {
        if !matches!(e, Event::Tick { .. }) {
            println!("event: {e:?}");
        }
        let _ = tx.send(e);
    });
    let rec = b.start(picked, opts, sink).expect("start");
    std::thread::sleep(Duration::from_secs_f64(secs / 2.0));
    rec.toggle_pause();
    std::thread::sleep(Duration::from_secs(1));
    rec.toggle_pause();
    std::thread::sleep(Duration::from_secs_f64(secs / 2.0));
    println!("elapsed {:.2}", rec.elapsed());
    rec.stop();
    loop {
        match rx.recv_timeout(Duration::from_secs(30)).expect("no finish") {
            Event::Finished { folder } => {
                let p = monetshot_core::Project::load(&folder).expect("load");
                println!("ok: {} meta={:?} samples={} clicks={} cuts={:?}", folder.display(), p.meta(), p.cursor().samples.len(), p.cursor().clicks.len(), p.edit.cuts);
                break;
            }
            Event::Failed(m) => panic!("failed: {m}"),
            _ => {}
        }
    }
}
