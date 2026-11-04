//! Text overlays as pictures (a port of `Render/TextArt.swift`), in Inter
//! Bold from `Resources/Fonts`, the file the Mac draws with. Laid out glyph
//! by glyph with the shared em metrics (`text_motion`), no shaping or
//! kerning, so each letter lands where the Mac puts it. The preview draws
//! this same picture (core-wasm's `textArt`).

use crate::art::{blur_alpha, em_scale, paint, q, rgb, rounded, FONT};
use ab_glyph::{Font, FontRef, ScaleFont};
use monetshot_core::plan::TextPlan;
use monetshot_core::text::text_motion::{BASELINE, LINE_HEIGHT, PAD_X, PAD_Y, RADIUS, SHADOW_ALPHA, SHADOW_OFFSET, SHADOW_SIGMA};
use tiny_skia::{Pixmap, Rect, Transform};

/// A text's picture: premultiplied sRGB RGBA8, drawn at canvas scale.
#[derive(Debug, Clone, PartialEq)]
pub struct TextArt {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

/// Pen positions of one line's characters at `px`, and its width.
pub fn line_layout(line: &str, px: f32, tracking: f32) -> (Vec<(char, ab_glyph::GlyphId, f32)>, f32) {
    let font = FontRef::try_from_slice(FONT).expect("bundled font");
    let sf = font.as_scaled(em_scale(&font, px));
    let mut x = 0.0;
    let mut out = vec![];
    for (k, c) in line.chars().enumerate() {
        if k > 0 {
            x += tracking * px;
        }
        let g = sf.glyph_id(c);
        out.push((c, g, x));
        x += sf.h_advance(g);
    }
    (out, x)
}

/// Draws the picture for `plan` (its opacity, scale and centre are the
/// painter's to apply).
pub fn text_art(plan: &TextPlan) -> TextArt {
    let px = plan.px.max(1.0) as f32;
    let font = FontRef::try_from_slice(FONT).expect("bundled font");
    let lines: Vec<_> = plan.lines.iter().map(|l| line_layout(l, px, plan.tracking as f32)).collect();
    let block_w = lines.iter().map(|l| l.1).fold(0.0f32, f32::max);
    let lh = LINE_HEIGHT as f32 * px;
    let (pad_x, pad_y) = (PAD_X as f32 * px, PAD_Y as f32 * px);
    let w = (block_w + 2.0 * pad_x).ceil().max(1.0) as usize;
    let h = (lines.len() as f32 * lh + 2.0 * pad_y).ceil().max(1.0) as usize;
    let mut pm = Pixmap::new(w as u32, h as u32).expect("text picture size");

    if let Some(b) = &plan.backing {
        let hex = ((b.r * 255.0).round() as u32) << 16 | ((b.g * 255.0).round() as u32) << 8 | (b.b * 255.0).round() as u32;
        let rect = Rect::from_xywh(0.0, 0.0, w as f32, h as f32).unwrap();
        pm.fill_path(&rounded(rect, RADIUS as f32 * px), &paint(rgb(hex, b.a as f32)), tiny_skia::FillRule::Winding, Transform::identity(), None);
    }

    // Coverage of the words, each at its own alpha.
    let mut cov = vec![0f32; w * h];
    let scale = em_scale(&font, px);
    let mut word: i64 = -1;
    for (i, (glyphs, line_w)) in lines.iter().enumerate() {
        let x0 = (w as f32 - line_w) / 2.0;
        let baseline = pad_y + i as f32 * lh + BASELINE as f32 * px;
        let mut in_word = false;
        for &(c, g, gx) in glyphs {
            let space = c == ' ' || c == '\t';
            if !space && !in_word {
                word += 1;
            }
            in_word = !space;
            if space {
                continue;
            }
            let alpha = if plan.words.is_empty() { 1.0 } else { plan.words.get(word as usize).copied().unwrap_or(0.0) as f32 };
            if alpha <= 0.001 {
                continue;
            }
            if let Some(o) = font.outline_glyph(g.with_scale_and_position(scale, ab_glyph::point(x0 + gx, baseline))) {
                let b = o.px_bounds();
                o.draw(|gx, gy, c| {
                    let (x, y) = (b.min.x as i64 + gx as i64, b.min.y as i64 + gy as i64);
                    if x >= 0 && y >= 0 && (x as usize) < w && (y as usize) < h {
                        let k = y as usize * w + x as usize;
                        cov[k] = (cov[k] + c * alpha).min(1.0);
                    }
                });
            }
        }
    }

    // CoreGraphics and tiny-skia both blend in gamma space: so do we.
    let data = pm.data_mut();
    let mut over = |k: usize, col: [f32; 3], a: f32| {
        if a <= 0.0 {
            return;
        }
        let p = &mut data[k * 4..k * 4 + 4];
        for c in 0..3 {
            p[c] = q(col[c] * a + p[c] as f32 / 255.0 * (1.0 - a));
        }
        p[3] = q(a + p[3] as f32 / 255.0 * (1.0 - a));
    };
    if plan.shadow {
        let mut sh = vec![0f32; w * h];
        let dy = (SHADOW_OFFSET as f32 * px).round() as usize;
        for y in dy..h {
            sh[y * w..y * w + w].copy_from_slice(&cov[(y - dy) * w..(y - dy) * w + w]);
        }
        blur_alpha(&mut sh, w, h, SHADOW_SIGMA as f32 * px);
        for (k, a) in sh.iter().enumerate() {
            over(k, [0.04, 0.035, 0.03], a * SHADOW_ALPHA as f32);
        }
    }
    let col = [plan.color.r as f32, plan.color.g as f32, plan.color.b as f32];
    for (k, a) in cov.iter().enumerate() {
        over(k, col, *a);
    }
    TextArt { width: w as u32, height: h as u32, rgba: pm.take() }
}
