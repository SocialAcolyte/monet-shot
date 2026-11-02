//! `cargo run -p monetshot-export --example art_sheet -- out.png`: every
//! cursor style and tint, our art on the left of each pair, the Mac's right.
use monetshot_core::cursor::{CursorStyle, CursorTint};
fn main() {
    let out = std::env::args().nth(1).expect("out.png");
    let fx = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../shared/fixtures/render");
    let (cell, cols) = (150u32, 12u32);
    let rows = CursorStyle::ALL.len() as u32;
    let mut sheet = image::RgbaImage::from_pixel(cell * cols, cell * rows, image::Rgba([237, 235, 230, 255]));
    for (r, style) in CursorStyle::ALL.iter().enumerate() {
        for (c, tint) in CursorTint::ALL.iter().enumerate() {
            let a = monetshot_export::cursor_art(style, tint, "Connor", 66);
            let mut img = image::RgbaImage::from_raw(a.width, a.height, a.rgba).unwrap();
            for p in img.pixels_mut() {
                let al = p[3] as u32;
                if al > 0 { for v in 0..3 { p[v] = ((p[v] as u32 * 255 + al / 2) / al).min(255) as u8; } }
            }
            let x = (c as u32 * 2) * cell + 20;
            image::imageops::overlay(&mut sheet, &img, x as i64, (r as u32 * cell + 20) as i64);
            let mac = fx.join(format!("cursor-{}-{}-66.png", style.as_str(), if style.tinted() { tint.as_str() } else { "clay" }));
            if let Ok(m) = image::open(mac) {
                image::imageops::overlay(&mut sheet, &m.to_rgba8(), (x + cell) as i64, (r as u32 * cell + 20) as i64);
            }
        }
    }
    sheet.save(out).unwrap();
}
