//! The cursor Monet Shot draws, as vectors: a port of `Render/CursorArt.swift`
//! on tiny-skia. CoreGraphics blends in gamma space; so does tiny-skia. The
//! name tag uses Inter Bold (bundled) where the Mac uses the system's bold UI
//! font, so the tag is a few pixels wider or narrower than the Mac's.

use ab_glyph::{Font, FontRef, ScaleFont};
use monetshot_core::cursor::{CursorStyle, CursorTint};
use tiny_skia::{
    Color, FillRule, LineCap, LineJoin, Mask, Paint, Path, PathBuilder, Pixmap, Rect, Stroke, Transform,
};

pub(crate) static FONT: &[u8] = include_bytes!("../../../../Resources/Fonts/Inter-Bold.ttf");

/// A rendered cursor: premultiplied sRGB RGBA8, and the hotspot (the tip,
/// or the dot's centre) in pixels from the top-left.
#[derive(Debug, Clone, PartialEq)]
pub struct CursorArt {
    pub width: u32,
    pub height: u32,
    pub tip_x: f64,
    pub tip_y: f64,
    pub rgba: Vec<u8>,
}

const GRID_HEIGHT: f32 = 22.0;
const OUTLINE: [(f32, f32); 7] = [(0.0, 0.0), (0.0, 18.2), (4.3, 14.1), (7.4, 21.0), (10.6, 19.6), (7.6, 12.8), (13.4, 12.8)];
const SOFT_OUTLINE: [(f32, f32); 7] = [(0.0, 0.0), (0.0, 16.4), (4.6, 12.6), (7.2, 18.4), (10.4, 17.0), (7.9, 11.4), (13.6, 11.4)];

pub(crate) fn rgb(hex: u32, a: f32) -> Color {
    Color::from_rgba(((hex >> 16) & 0xFF) as f32 / 255.0, ((hex >> 8) & 0xFF) as f32 / 255.0, (hex & 0xFF) as f32 / 255.0, a).unwrap()
}

pub(crate) fn paint(c: Color) -> Paint<'static> {
    let mut p = Paint::default();
    p.set_color(c);
    p.anti_alias = true;
    p
}

fn stroke(width: f32) -> Stroke {
    Stroke { width, line_cap: LineCap::Round, line_join: LineJoin::Round, ..Default::default() }
}

fn polygon(pts: &[(f32, f32)], s: f32) -> Path {
    let mut b = PathBuilder::new();
    b.move_to(pts[0].0 * s, pts[0].1 * s);
    for p in &pts[1..] {
        b.line_to(p.0 * s, p.1 * s);
    }
    b.close();
    b.finish().unwrap()
}

pub(crate) fn rounded(r: Rect, radius: f32) -> Path {
    let radius = radius.min(r.width() / 2.0).min(r.height() / 2.0).max(0.0);
    let k = 0.552_284_8 * radius;
    let (x0, y0, x1, y1) = (r.left(), r.top(), r.right(), r.bottom());
    let mut b = PathBuilder::new();
    b.move_to(x0 + radius, y0);
    b.line_to(x1 - radius, y0);
    b.cubic_to(x1 - radius + k, y0, x1, y0 + radius - k, x1, y0 + radius);
    b.line_to(x1, y1 - radius);
    b.cubic_to(x1, y1 - radius + k, x1 - radius + k, y1, x1 - radius, y1);
    b.line_to(x0 + radius, y1);
    b.cubic_to(x0 + radius - k, y1, x0, y1 - radius + k, x0, y1 - radius);
    b.line_to(x0, y0 + radius);
    b.cubic_to(x0, y0 + radius - k, x0 + radius - k, y0, x0 + radius, y0);
    b.close();
    b.finish().unwrap()
}

fn ellipse(r: Rect) -> Path {
    PathBuilder::from_oval(r).unwrap()
}

enum Draw<'a> {
    Fill(&'a Path),
    Stroke(&'a Path, f32),
}

/// Draws the CoreGraphics-style shadow `what` would cast (the caller draws
/// `what` itself after):
/// `dy` down (pixels), blurred by `blur` (CG's blur ≈ 2 sigma).
/// CoreGraphics scales the shadow by the alpha of what casts it (`alpha`).
fn with_shadow(pm: &mut Pixmap, t: Transform, what: &Draw, shadow: Color, caster_alpha: f32, dy: f32, blur: f32) {
    let (w, h) = (pm.width(), pm.height());
    let mut layer = Pixmap::new(w, h).unwrap();
    let st = t.post_translate(0.0, dy);
    let black = paint(Color::BLACK);
    match what {
        Draw::Fill(p) => layer.fill_path(p, &black, FillRule::Winding, st, None),
        Draw::Stroke(p, width) => layer.stroke_path(p, &black, &stroke(*width), st, None),
    }
    let mut alpha: Vec<f32> = layer.pixels().iter().map(|p| p.alpha() as f32 / 255.0).collect();
    blur_alpha(&mut alpha, w as usize, h as usize, blur / 2.0);
    let (sr, sg, sb, sa) = (shadow.red(), shadow.green(), shadow.blue(), shadow.alpha() * caster_alpha);
    for (px, a) in pm.pixels_mut().iter_mut().zip(alpha) {
        let a = (a * sa).clamp(0.0, 1.0);
        if a <= 0.0 {
            continue;
        }
        let inv = 1.0 - a;
        let c = [px.red(), px.green(), px.blue(), px.alpha()].map(|v| v as f32 / 255.0);
        let out = [sr * a + c[0] * inv, sg * a + c[1] * inv, sb * a + c[2] * inv, a + c[3] * inv];
        *px = tiny_skia::PremultipliedColorU8::from_rgba(
            q(out[0].min(out[3])),
            q(out[1].min(out[3])),
            q(out[2].min(out[3])),
            q(out[3]),
        )
        .unwrap();
    }
}

pub(crate) fn q(v: f32) -> u8 {
    (v.clamp(0.0, 1.0) * 255.0 + 0.5) as u8
}

/// Gaussian blur of a single channel, edges transparent (three box passes).
pub(crate) fn blur_alpha(a: &mut [f32], w: usize, h: usize, sigma: f32) {
    if sigma < 0.3 {
        return;
    }
    for r in boxes(sigma) {
        box_pass(a, w, h, r, true);
        box_pass(a, w, h, r, false);
    }
}

fn boxes(sigma: f32) -> [usize; 3] {
    // Box radii whose three passes approximate the gaussian.
    let n = 3.0;
    let ideal = (12.0 * sigma * sigma / n + 1.0).sqrt();
    let mut wl = ideal.floor() as i64;
    if wl % 2 == 0 {
        wl -= 1;
    }
    let wu = wl + 2;
    let wlf = wl as f32;
    let m = ((12.0 * sigma * sigma - n * wlf * wlf - 4.0 * n * wlf - 3.0 * n) / (-4.0 * wlf - 4.0)).round() as i64;
    let mut out = [0usize; 3];
    for (i, o) in out.iter_mut().enumerate() {
        let size = if (i as i64) < m { wl } else { wu };
        *o = ((size.max(1) - 1) / 2) as usize;
    }
    out
}

fn box_pass(a: &mut [f32], w: usize, h: usize, r: usize, horizontal: bool) {
    if r == 0 {
        return;
    }
    let (n, lines) = if horizontal { (w, h) } else { (h, w) };
    let idx = |line: usize, i: usize| if horizontal { line * w + i } else { i * w + line };
    let mut buf = vec![0f32; n];
    let norm = 1.0 / (2 * r + 1) as f32;
    for line in 0..lines {
        let get = |i: i64| if i < 0 || i >= n as i64 { 0.0 } else { a[idx(line, i as usize)] };
        let mut sum: f32 = (-(r as i64)..=r as i64).map(get).sum();
        for (i, b) in buf.iter_mut().enumerate() {
            *b = sum * norm;
            sum += get(i as i64 + r as i64 + 1) - get(i as i64 - r as i64);
        }
        for (i, b) in buf.iter().enumerate() {
            a[idx(line, i)] = *b;
        }
    }
}

/// Lays out `text` in the bundled bold font at `size` px: (glyphs, width).
/// CoreText sizes are em sizes; ab_glyph scales by ascent-to-descent.
pub(crate) fn em_scale(font: &FontRef, size: f32) -> ab_glyph::PxScale {
    let upem = font.units_per_em().unwrap_or(1000.0);
    ab_glyph::PxScale::from(size * font.height_unscaled() / upem)
}

fn layout(text: &str, size: f32) -> (Vec<(ab_glyph::GlyphId, f32)>, f32) {
    let font = FontRef::try_from_slice(FONT).expect("bundled font");
    let sf = font.as_scaled(em_scale(&font, size));
    let mut x = 0.0;
    let mut out = vec![];
    let mut prev: Option<ab_glyph::GlyphId> = None;
    for c in text.chars() {
        let g = sf.glyph_id(c);
        if let Some(p) = prev {
            x += sf.kern(p, g);
        }
        out.push((g, x));
        x += sf.h_advance(g);
        prev = Some(g);
    }
    (out, x)
}

fn draw_text(pm: &mut Pixmap, text: &str, size: f32, x: f32, baseline: f32, color: Color) {
    let font = FontRef::try_from_slice(FONT).expect("bundled font");
    let (glyphs, _) = layout(text, size);
    let (w, h) = (pm.width() as i64, pm.height() as i64);
    let mut cov = vec![0f32; (w * h) as usize];
    for (g, gx) in glyphs {
        let glyph = g.with_scale_and_position(em_scale(&font, size), ab_glyph::point(x + gx, baseline));
        if let Some(o) = font.outline_glyph(glyph) {
            let b = o.px_bounds();
            o.draw(|px, py, c| {
                let (xx, yy) = (b.min.x as i64 + px as i64, b.min.y as i64 + py as i64);
                if xx >= 0 && yy >= 0 && xx < w && yy < h {
                    let i = (yy * w + xx) as usize;
                    cov[i] = (cov[i] + c).min(1.0);
                }
            });
        }
    }
    let mut mask = Mask::new(w as u32, h as u32).unwrap();
    for (m, c) in mask.data_mut().iter_mut().zip(cov) {
        *m = q(c);
    }
    let rect = Rect::from_xywh(0.0, 0.0, w as f32, h as f32).unwrap();
    pm.fill_rect(rect, &paint(color), Transform::identity(), Some(&mask));
}

/// Renders the cursor so its arrow is `pixel_height` tall (plus room for
/// rim, shadow and any tag). `label` "" draws "You" on the tag.
pub fn cursor_art(style: &CursorStyle, tint: &CursorTint, label: &str, pixel_height: u32) -> CursorArt {
    let style = style.known();
    let tint_hex = tint.hex();
    let s = pixel_height.max(1) as f32 / GRID_HEIGHT;
    let margin = (4.0 * s).ceil();
    let tag_text: String = if label.is_empty() { "You".into() } else { label.chars().take(18).collect() };
    let font_size = 7.4 * s;
    let (_, text_w) = layout(&tag_text, font_size);
    let pill = Rect::from_xywh(11.5 * s, 15.5 * s, text_w + 9.0 * s, 12.0 * s).unwrap();

    let (cw, ch) = match style {
        CursorStyle::Dot => (22.0 * s, 22.0 * s),
        CursorStyle::Tag => (pill.right() + s, pill.bottom() + s),
        _ => (14.0 * s, 22.0 * s),
    };
    let w = (cw + margin * 2.0).ceil() as u32;
    let h = (ch + margin * 2.0).ceil() as u32;
    let mut pm = Pixmap::new(w, h).unwrap();
    let t = Transform::from_translate(margin, margin);
    let shadow = rgb(0x000000, 0.32);
    let white = rgb(0xFFFFFF, 1.0);
    let ink = Color::from_rgba(0.06, 0.06, 0.07, 1.0).unwrap();
    let tint_c = rgb(tint_hex, 1.0);

    match style {
        CursorStyle::Classic | CursorStyle::White => {
            let path = polygon(&OUTLINE, s);
            let (body, rim) = if style == CursorStyle::Classic { (ink, white) } else { (white, ink) };
            with_shadow(&mut pm, t, &Draw::Fill(&path), shadow, 1.0, 0.8 * s, 2.2 * s);
            pm.fill_path(&path, &paint(rim), FillRule::Winding, t, None);
            let rw = if style == CursorStyle::Classic { 2.4 } else { 1.8 } * s;
            pm.stroke_path(&path, &paint(rim), &stroke(rw), t, None);
            pm.fill_path(&path, &paint(body), FillRule::Winding, t, None);
        }
        CursorStyle::Soft | CursorStyle::Tag => {
            let path = polygon(&SOFT_OUTLINE, s);
            with_shadow(&mut pm, t, &Draw::Stroke(&path, 4.4 * s), shadow, 1.0, s, 2.6 * s);
            pm.stroke_path(&path, &paint(white), &stroke(4.4 * s), t, None);
            // A thick round stroke in the body colour rounds every corner.
            pm.stroke_path(&path, &paint(tint_c), &stroke(1.6 * s), t, None);
            pm.fill_path(&path, &paint(tint_c), FillRule::Winding, t, None);
            if style == CursorStyle::Tag {
                let r = pill.height() / 2.0;
                let pill_path = rounded(pill, r);
                with_shadow(&mut pm, t, &Draw::Fill(&pill_path), shadow, 1.0, s, 2.6 * s);
                pm.fill_path(&pill_path, &paint(white), FillRule::Winding, t, None);
                let inner = Rect::from_ltrb(pill.left() + 0.9 * s, pill.top() + 0.9 * s, pill.right() - 0.9 * s, pill.bottom() - 0.9 * s).unwrap();
                pm.fill_path(&rounded(inner, r - 0.9 * s), &paint(tint_c), FillRule::Winding, t, None);
                let mid_y = pill.top() + pill.height() / 2.0;
                draw_text(&mut pm, &tag_text, font_size, margin + pill.left() + 4.5 * s, margin + mid_y + 2.6 * s, white);
            }
        }
        _ => {
            let disc = Rect::from_xywh(2.0 * s, 2.0 * s, 18.0 * s, 18.0 * s).unwrap();
            let inset = |d: f32| Rect::from_ltrb(disc.left() + d, disc.top() + d, disc.right() - d, disc.bottom() - d).unwrap();
            let d = ellipse(disc);
            with_shadow(&mut pm, t, &Draw::Fill(&d), rgb(0x000000, 0.22), 0.42, 0.8 * s, 3.0 * s);
            pm.fill_path(&d, &paint(rgb(tint_hex, 0.42)), FillRule::Winding, t, None);
            pm.stroke_path(&ellipse(inset(0.9 * s)), &paint(rgb(0xFFFFFF, 0.95)), &stroke(1.8 * s), t, None);
            pm.fill_path(&ellipse(inset(6.4 * s)), &paint(rgb(tint_hex, 0.9)), FillRule::Winding, t, None);
        }
    }
    let (tip_x, tip_y) = if style == CursorStyle::Dot {
        ((margin + 11.0 * s) as f64, (margin + 11.0 * s) as f64)
    } else {
        (margin as f64, margin as f64)
    };
    CursorArt { width: w, height: h, tip_x, tip_y, rgba: pm.take() }
}
