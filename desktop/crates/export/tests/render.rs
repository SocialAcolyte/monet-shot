//! Our painter against frames the Mac's Renderer drew
//! (`shared/fixtures/render/cases.json`, `vertical.json`). Set MONETSHOT_RENDER_OUT=<dir> to
//! write ours beside them for a look.

use monetshot_core::json::from_json;
use monetshot_core::plan::{PlanTake, Planner};
use monetshot_core::{EditDoc, RecordingMeta};
use monetshot_export::{Painter, Rgba8};
use serde_json::Value;
use std::path::PathBuf;

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn load(p: PathBuf) -> Rgba8 {
    let i = image::open(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display())).to_rgba8();
    Rgba8::new(i.width(), i.height(), i.into_raw())
}

/// Mean |difference| (0-255) over RGB, and the share of pixels off by more than 24.
fn compare(a: &Rgba8, b: &Rgba8) -> (f64, f64) {
    assert_eq!((a.width, a.height), (b.width, b.height));
    let mut sum = 0u64;
    let mut bad = 0u64;
    for (p, q) in a.data.chunks(4).zip(b.data.chunks(4)) {
        let mut worst = 0;
        for c in 0..3 {
            let d = (p[c] as i32 - q[c] as i32).abs();
            sum += d as u64;
            worst = worst.max(d);
        }
        if worst > 24 {
            bad += 1;
        }
    }
    let n = (a.width * a.height) as f64;
    (sum as f64 / (n * 3.0), bad as f64 / n)
}

#[test]
fn painter_matches_the_macs_renderer() {
    matches_the_mac("cases.json");
}

/// Vertical and square frames (1080x1920, 1080x1080): the follow window.
#[test]
fn vertical_matches_the_macs_renderer() {
    matches_the_mac("vertical.json");
}

fn matches_the_mac(file: &str) {
    let fx = repo().join("shared/fixtures/render");
    let cases: Value = serde_json::from_slice(&std::fs::read(fx.join(file)).unwrap()).unwrap();
    let out = std::env::var_os("MONETSHOT_RENDER_OUT").map(PathBuf::from);
    let mut report = vec![];
    let mut failures = vec![];
    for c in cases["cases"].as_array().unwrap() {
        let name = c["name"].as_str().unwrap();
        let doc: EditDoc = from_json(c["edit"].as_str().unwrap().as_bytes()).unwrap();
        let overlay = c["overlay"].as_bool().unwrap();
        let has_webcam = !c["webcam"].is_null();
        let takes: Vec<PlanTake> = c["takes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| {
                let mut meta: RecordingMeta = from_json(t["meta"].as_str().unwrap().as_bytes()).unwrap();
                // The Mac case hands the renderer a camera frame directly; here
                // that is a take camera starting with the take.
                if has_webcam && !overlay {
                    meta.camera = Some("webcam.png".into());
                    meta.camera_offset = 0.0;
                }
                PlanTake { meta, cursor: from_json(t["cursor"].as_str().unwrap().as_bytes()).unwrap(), dir: String::new() }
            })
            .collect();
        let transcripts: Vec<Option<monetshot_core::Transcript>> = c
            .get("transcripts")
            .and_then(|v| v.as_array())
            .map(|a| a.iter().map(|t| t.as_str().map(|s| from_json(s.as_bytes()).unwrap())).collect())
            .unwrap_or_default();
        let planner = Planner::new(&doc, &takes).with_transcripts(&transcripts);
        let plan = planner.plan(c["t"].as_f64().unwrap());
        let sources = c["sources"].as_array().unwrap();
        let source = load(fx.join(sources[plan.take as usize].as_str().unwrap()));
        let webcam = has_webcam.then(|| load(fx.join("webcam.png")));
        let mut painter = Painter::new(&planner, Some(&repo().join(c["backdropFolder"].as_str().unwrap())));
        let t0 = std::time::Instant::now();
        let ours = painter.paint(&plan, &source, webcam.as_ref().map(|w| (0, w)));
        let ms = t0.elapsed().as_millis();
        let mac = load(fx.join(c["file"].as_str().unwrap()));
        let (mean, bad) = compare(&ours, &mac);
        report.push(format!("{name}: mean {mean:.2}/255, {:.2}% px off by >24, {ms} ms", bad * 100.0));
        if let Some(dir) = &out {
            std::fs::create_dir_all(dir).unwrap();
            image::RgbaImage::from_raw(ours.width, ours.height, ours.data.clone()).unwrap().save(dir.join(format!("{name}.png"))).unwrap();
            let diff: Vec<u8> = ours
                .data
                .chunks(4)
                .zip(mac.data.chunks(4))
                .flat_map(|(p, q)| {
                    let d = (0..3).map(|c| (p[c] as i32 - q[c] as i32).abs()).max().unwrap();
                    let v = (d * 8).min(255) as u8;
                    [v, if d > 24 { 0 } else { v }, if d > 24 { 0 } else { v }, 255]
                })
                .collect();
            image::RgbaImage::from_raw(ours.width, ours.height, diff).unwrap().save(dir.join(format!("{name}-diff.png"))).unwrap();
        }
        // Text is rasterised by CoreText on the Mac and ab_glyph here (same
        // font, same layout to 0.05 px; see art.rs): glyph edges anti-alias
        // a little differently, so frames with words get more room there.
        let edges = if doc.overlays().is_empty() && planner.captions.is_empty() { 0.005 } else { 0.008 };
        if !(mean < 1.5 && bad < edges) {
            failures.push(name.to_string());
        }
    }
    eprintln!("{}", report.join("\n"));
    assert!(failures.is_empty(), "differ from the Mac: {failures:?}");
}
