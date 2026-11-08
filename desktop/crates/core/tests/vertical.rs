//! Vertical and square (`shared/fixtures/vertical.json`, made by
//! `shared/tools/fixtures.sh` from the Swift Kit): canvas sizes, the safe
//! area, the follow window, texts in the safe area, and whole layouts with
//! the follow camera sampled every 0.05 s.

use monetshot_core::json::from_json;
use monetshot_core::plan::{in_safe_area, PlanTake, Planner, PHONE_BUBBLE};
use monetshot_core::vertical::{self, CanvasLayout};
use monetshot_core::*;
use serde_json::Value;
use std::path::PathBuf;

fn fixture(name: &str) -> Value {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../shared/fixtures").join(name);
    let bytes = std::fs::read(&p).unwrap_or_else(|e| panic!("{}: {e} (run shared/tools/fixtures.sh)", p.display()));
    serde_json::from_slice(&bytes).unwrap()
}
fn f(v: &Value) -> f64 {
    v.as_f64().unwrap_or_else(|| panic!("not a number: {v}"))
}
fn arr(v: &Value) -> &Vec<Value> {
    v.as_array().unwrap_or_else(|| panic!("not an array: {v}"))
}
#[track_caller]
fn near(a: f64, b: f64, what: &str) {
    let tol = 1e-9 * (1.0 + a.abs().max(b.abs()));
    assert!((a - b).abs() <= tol, "{what}: rust {a} vs mac {b}");
}
#[track_caller]
fn same_camera(a: Camera, b: &Value, what: &str) {
    near(a.scale, f(&b["scale"]), what);
    near(a.center_x, f(&b["centerX"]), what);
    near(a.center_y, f(&b["centerY"]), what);
    near(a.window, b.get("window").map_or(1.0, f), what);
}
fn edit(v: &Value) -> EditDoc {
    from_json(v.as_str().unwrap().as_bytes()).unwrap()
}

#[test]
fn constants() {
    let c = &fixture("vertical.json")["constants"];
    assert_eq!(vertical::ZOOM_DEPTH, f(&c["zoomDepth"]));
    assert_eq!(vertical::DEAD_ZONE, f(&c["deadZone"]));
    assert_eq!(vertical::OMEGA, f(&c["omega"]));
    assert_eq!(PHONE_BUBBLE, f(&c["phoneBubble"]));
    assert_eq!(vertical::CAPTION_BAND, f(&c["captionBand"]));
}

#[test]
fn canvas_sizes() {
    for c in arr(&fixture("vertical.json")["canvas"]) {
        let doc = edit(&c["edit"]);
        assert_eq!(doc.canvas_layout().as_str(), c["layout"].as_str().unwrap());
        let (w, h) = doc.canvas_size(f(&c["recordingAspect"]));
        assert_eq!((w, h), (c["width"].as_i64().unwrap(), c["height"].as_i64().unwrap()), "{c}");
        // The landscape keys are untouched, and landscape writes no layout key.
        assert_eq!(doc.output_width, c["outputWidth"].as_i64().unwrap());
        let json = to_swift_json(&doc).unwrap();
        assert_eq!(json.contains("\"layout\""), doc.canvas_layout() != CanvasLayout::Landscape, "{json}");
        assert_eq!(json, c["edit"].as_str().unwrap(), "byte-identical edit.json");
    }
}

#[test]
fn safe_areas_and_windows() {
    let fx = fixture("vertical.json");
    for c in arr(&fx["safeArea"]) {
        let r = safe_area(f(&c["width"]), f(&c["height"]));
        assert_eq!((r.x, r.y, r.w, r.h), (f(&c["x"]), f(&c["y"]), f(&c["w"]), f(&c["h"])), "{c}");
    }
    for c in arr(&fx["window"]) {
        let w = vertical::window(f(&c["takeAspect"]), f(&c["frameAspect"]));
        match (w, c["window"].as_f64()) {
            (Some(a), Some(b)) => near(a, b, "window"),
            (None, None) => {}
            other => panic!("{c}: {other:?}"),
        }
    }
    for c in arr(&fx["texts"]) {
        let o: TextOverlay = from_json(c["overlay"].as_str().unwrap().as_bytes()).unwrap();
        let (w, h) = (f(&c["width"]), f(&c["height"]));
        let st = text_motion::state(&in_safe_area(&o, w, h), 1.5, w, h).unwrap();
        near(st.center_x, f(&c["centerX"]), "text x");
        near(st.center_y, f(&c["centerY"]), "text y");
        near(st.px, f(&c["px"]), "text px");
    }
}

#[test]
fn follow_layouts() {
    for c in arr(&fixture("vertical.json")["cases"]) {
        let name = c["name"].as_str().unwrap();
        let doc = edit(&c["edit"]);
        let takes: Vec<PlanTake> = arr(&c["takes"])
            .iter()
            .map(|t| PlanTake {
                meta: from_json(t["meta"].as_str().unwrap().as_bytes()).unwrap(),
                cursor: from_json(t["cursor"].as_str().unwrap().as_bytes()).unwrap(),
                dir: String::new(),
            })
            .collect();
        let p = Planner::new(&doc, &takes);
        assert_eq!((p.canvas.width as f64, p.canvas.height as f64), (f(&c["canvas"][0]), f(&c["canvas"][1])), "{name} canvas");
        assert_eq!(p.cursor_art_height as f64, f(&c["cursorArtHeight"]), "{name} art height");
        let b = p.bubble_rect();
        let wb = &c["bubbleRect"];
        assert_eq!((b.x, b.y, b.w, b.h), (f(&wb["x"]), f(&wb["y"]), f(&wb["w"]), f(&wb["h"])), "{name} bubble");
        for (k, l) in arr(&c["looks"]).iter().enumerate() {
            let fr = p.frame_rect(k as i64);
            let w = &l["frame"];
            assert_eq!((fr.x, fr.y, fr.w, fr.h), (f(&w["x"]), f(&w["y"]), f(&w["w"]), f(&w["h"])), "{name} frame {k}");
        }
        for q in arr(&c["frames"]) {
            let t = f(&q["t"]);
            let what = format!("{name} at {t}");
            let plan = p.plan(t);
            assert_eq!(plan.take, q["take"].as_i64().unwrap(), "{what}");
            same_camera(plan.camera, &q["camera"], &what);
            match (&plan.cursor, q.get("cursorTip")) {
                (Some(cur), Some(tip)) => {
                    near(cur.tip.x, f(&tip[0]), &format!("{what} tip x"));
                    near(cur.tip.y, f(&tip[1]), &format!("{what} tip y"));
                    near(cur.height, f(&q["cursorHeight"]), &format!("{what} cursor height"));
                    assert_eq!(plan.ripples.len(), arr(&q["ripples"]).len(), "{what} ripples");
                    for (a, b) in plan.ripples.iter().zip(arr(&q["ripples"])) {
                        near(a.radius, f(&b["radius"]), &what);
                    }
                }
                (None, None) => {}
                _ => panic!("{what}: cursor {:?} vs {:?}", plan.cursor, q.get("cursorTip")),
            }
            // The window shows what the frame holds: same shape, so one scale.
            let (fr, src) = (plan.frame, plan.source.rect);
            near(fr.w / src.w, fr.h / src.h, &format!("{what} one scale"));
        }
        for q in arr(&c["cameras"]) {
            let t = f(&q["t"]);
            same_camera(p.camera_at(t), &q["camera"], &format!("{name} camera at {t}"));
        }
    }
}

/// The glide is calm: no jitter (the centre never reverses within a few
/// frames) and it rests when the action rests.
#[test]
fn follow_is_calm() {
    for c in arr(&fixture("vertical.json")["cases"]) {
        let name = c["name"].as_str().unwrap();
        let xs: Vec<f64> = arr(&c["cameras"]).iter().map(|q| f(&q["camera"]["centerX"])).collect();
        // Speed in picture widths per second, sampled at 20 Hz: a calm camera
        // never whips (the zoom ramps and clip cuts aside, which jump by design).
        let fast = xs.windows(2).filter(|w| (w[1] - w[0]).abs() * 20.0 > 1.5).count();
        assert!(fast <= 3, "{name}: {fast} whips");
    }
}
