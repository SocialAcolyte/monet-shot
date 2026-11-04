//! Our cursor art against the Mac's (`shared/fixtures/render/cursor-*.png`).

use monetshot_core::cursor::{CursorStyle, CursorTint};
use monetshot_export::cursor_art;
use serde_json::Value;
use std::path::PathBuf;

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../shared/fixtures")
}

/// Mean and 99th-percentile absolute difference (0-255) over premultiplied
/// RGBA, comparing the overlapping area aligned at the top-left.
pub fn diff(a: &[u8], aw: u32, ah: u32, b: &[u8], bw: u32, bh: u32) -> (f64, u8) {
    let (w, h) = (aw.min(bw), ah.min(bh));
    let mut sum = 0u64;
    let mut hist = [0u64; 256];
    for y in 0..h {
        for x in 0..w {
            for c in 0..4 {
                let d = (a[((y * aw + x) * 4 + c) as usize] as i32 - b[((y * bw + x) * 4 + c) as usize] as i32).unsigned_abs() as usize;
                sum += d as u64;
                hist[d] += 1;
            }
        }
    }
    let n = (w * h * 4) as u64;
    let mut acc = 0;
    let mut p99 = 0;
    for (d, c) in hist.iter().enumerate() {
        acc += c;
        if acc * 100 >= n * 99 {
            p99 = d as u8;
            break;
        }
    }
    (sum as f64 / n as f64, p99)
}

#[test]
fn cursor_art_matches_the_mac() {
    let cases: Value = serde_json::from_slice(&std::fs::read(fixtures().join("cursor_art.json")).unwrap()).unwrap();
    let mut report = vec![];
    for c in cases["cases"].as_array().unwrap() {
        let style = CursorStyle::parse(c["style"].as_str().unwrap());
        let tint = CursorTint::parse(c["tint"].as_str().unwrap());
        let label = c["label"].as_str().unwrap();
        let h = c["pixelHeight"].as_u64().unwrap() as u32;
        let art = cursor_art(&style, &tint, label, h);
        let mac = image::open(fixtures().join("render").join(c["file"].as_str().unwrap())).unwrap().to_rgba8();
        // CGImage PNGs are straight alpha; ours is premultiplied.
        let mut mac_px = mac.as_raw().clone();
        for p in mac_px.chunks_mut(4) {
            let a = p[3] as u32;
            for v in &mut p[..3] {
                *v = ((*v as u32 * a + 127) / 255) as u8;
            }
        }
        let tag = style == CursorStyle::Tag;
        let (mw, mh) = (mac.width(), mac.height());
        if !tag {
            assert_eq!((art.width, art.height), (mw, mh), "{} size", c["file"]);
        } else {
            assert_eq!(art.height, mh, "{} height", c["file"]);
            assert!((art.width as i64 - mw as i64).abs() <= (h as i64) / 5, "{} width {} vs {}", c["file"], art.width, mw);
        }
        assert!((art.tip_x - c["tip"][0].as_f64().unwrap()).abs() < 1e-6 && (art.tip_y - c["tip"][1].as_f64().unwrap()).abs() < 1e-6);
        // The tag's text differs (another font): compare the arrow's part only.
        let cmp_w = if tag { (art.width.min(mw) as f64 * 0.45) as u32 } else { art.width };
        let (mean, p99) = diff_crop(&art.rgba, art.width, &mac_px, mw, cmp_w, art.height.min(mh));
        report.push(format!("{}: mean {mean:.2} p99 {p99}", c["file"].as_str().unwrap()));
        assert!(mean < 6.0 && p99 < 90, "{}: mean {mean:.2}, p99 {p99}", c["file"]);
    }
    eprintln!("{}", report.join("\n"));
}

fn diff_crop(a: &[u8], aw: u32, b: &[u8], bw: u32, w: u32, h: u32) -> (f64, u8) {
    let pick = |src: &[u8], sw: u32| -> Vec<u8> {
        (0..h).flat_map(|y| src[((y * sw) * 4) as usize..((y * sw + w) * 4) as usize].to_vec()).collect()
    };
    diff(&pick(a, aw), w, h, &pick(b, bw), w, h)
}

/// Text lines are laid out where the Mac lays them (pen positions from
/// `shared/fixtures/text.json`, made with CoreText and the same font).
#[test]
fn text_layout_matches_the_mac() {
    let p = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../shared/fixtures/text.json");
    let fx: serde_json::Value = serde_json::from_slice(&std::fs::read(p).unwrap()).unwrap();
    for c in fx["widths"].as_array().unwrap() {
        let (line, px, tracking) = (c["line"].as_str().unwrap(), c["px"].as_f64().unwrap() as f32, c["tracking"].as_f64().unwrap() as f32);
        let (glyphs, width) = monetshot_export::text_art::line_layout(line, px, tracking);
        let mac_w = c["width"].as_f64().unwrap() as f32;
        assert!((width - mac_w).abs() < 0.05, "{line} at {px}px: width {width} vs mac {mac_w}");
        for ((_, _, x), m) in glyphs.iter().zip(c["xs"].as_array().unwrap()) {
            assert!((x - m.as_f64().unwrap() as f32).abs() < 0.05, "{line}: pen {x} vs mac {m}");
        }
    }
}
