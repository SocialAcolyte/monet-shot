//! `cargo run --release -p monetshot-export --example export -- <reel> <out.mp4> [still-times...]`
//! Exports a recording (reads the .reel, never writes into it), and with
//! extra times writes PNG stills `<out>.<t>.png` instead.
use std::sync::atomic::AtomicBool;
fn main() {
    let args: Vec<String> = std::env::args().collect();
    let project = monetshot_core::Project::load(std::path::Path::new(&args[1])).expect("load");
    let out = std::path::PathBuf::from(&args[2]);
    if args.len() > 3 {
        for t in &args[3..] {
            let img = monetshot_export::render_still(&project, t.parse().unwrap(), None).expect("still");
            std::fs::write(format!("{}.{t}.png", out.display()), monetshot_export::export::png(&img).unwrap()).unwrap();
        }
        return;
    }
    let t0 = std::time::Instant::now();
    let last = std::sync::Mutex::new(0);
    monetshot_export::export(&project, &out, &|p| {
        let pc = (p * 10.0) as i32;
        let mut l = last.lock().unwrap();
        if pc > *l {
            *l = pc;
            eprintln!("{:.0}% {:.1}s", p * 100.0, t0.elapsed().as_secs_f64());
        }
    }, &AtomicBool::new(false))
    .expect("export");
    eprintln!("done in {:.1}s: {}", t0.elapsed().as_secs_f64(), out.display());
}
