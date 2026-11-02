//! The CPU painter: draws a `FramePlan` the way `Renderer.swift` draws it
//! with CoreImage, in linear light (decode sRGB, work, encode), so blurs,
//! shadows, gradients and scaling come out as on the Mac. Drawing order and
//! rules: `docs/porting/contracts/frame-plan.md`.

use crate::art::cursor_art;
use monetshot_core::cursor::{CursorStyle, CursorTint};
use monetshot_core::plan::{BackdropPlan, FramePlan, HideStyle, Planner, Rect, Rgba, WebcamPlan};
use rayon::prelude::*;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// An image as straight-alpha sRGB RGBA8 (video frames, stills, output).
#[derive(Debug, Clone, PartialEq)]
pub struct Rgba8 {
    pub width: u32,
    pub height: u32,
    pub data: Vec<u8>,
}

impl Rgba8 {
    pub fn new(width: u32, height: u32, data: Vec<u8>) -> Rgba8 {
        assert_eq!(data.len(), (width * height * 4) as usize, "RGBA8 size");
        Rgba8 { width, height, data }
    }
}

// MARK: colour

fn to_linear_lut() -> &'static [f32; 256] {
    static LUT: OnceLock<[f32; 256]> = OnceLock::new();
    LUT.get_or_init(|| {
        let mut t = [0f32; 256];
        for (i, v) in t.iter_mut().enumerate() {
            *v = decode(i as f32 / 255.0);
        }
        t
    })
}

const ENC_N: usize = 8192;
fn to_srgb_lut() -> &'static [u8] {
    static LUT: OnceLock<Vec<u8>> = OnceLock::new();
    LUT.get_or_init(|| (0..=ENC_N).map(|i| (encode(i as f32 / ENC_N as f32) * 255.0 + 0.5) as u8).collect())
}

pub fn decode(c: f32) -> f32 {
    if c <= 0.04045 {
        c / 12.92
    } else {
        ((c + 0.055) / 1.055).powf(2.4)
    }
}

pub fn encode(l: f32) -> f32 {
    let l = l.clamp(0.0, 1.0);
    if l <= 0.003_130_8 {
        l * 12.92
    } else {
        1.055 * l.powf(1.0 / 2.4) - 0.055
    }
}

#[inline]
fn enc8(l: f32) -> u8 {
    to_srgb_lut()[(l.clamp(0.0, 1.0) * ENC_N as f32 + 0.5) as usize]
}

fn lin(c: &Rgba) -> [f32; 3] {
    [decode(c.r as f32), decode(c.g as f32), decode(c.b as f32)]
}

// MARK: shapes

/// Coverage (0...1) of the pixel centred at (px, py) by a rounded rect.
#[inline]
fn rounded_cov(r: &Rect, radius: f64, px: f64, py: f64) -> f32 {
    let (hw, hh) = (r.w / 2.0, r.h / 2.0);
    let rad = radius.min(hw).min(hh).max(0.0);
    let (cx, cy) = (r.x + hw, r.y + hh);
    let qx = (px - cx).abs() - (hw - rad);
    let qy = (py - cy).abs() - (hh - rad);
    let outside = (qx.max(0.0).powi(2) + qy.max(0.0).powi(2)).sqrt();
    let sd = outside + qx.max(qy).min(0.0) - rad;
    (0.5 - sd).clamp(0.0, 1.0) as f32
}

/// The whole-pixel box around `r`, inside `w` x `h`: (x0, y0, x1, y1).
fn pixel_box(r: &Rect, w: usize, h: usize) -> (usize, usize, usize, usize) {
    let x0 = r.x.floor().max(0.0) as usize;
    let y0 = r.y.floor().max(0.0) as usize;
    let x1 = (r.max_x().ceil().max(0.0) as usize).min(w);
    let y1 = (r.max_y().ceil().max(0.0) as usize).min(h);
    (x0.min(x1), y0.min(y1), x1, y1)
}

// MARK: blur (three box passes approximate a gaussian)

fn box_radii(sigma: f64) -> [usize; 3] {
    let n = 3.0;
    let ideal = (12.0 * sigma * sigma / n + 1.0).sqrt();
    let mut wl = ideal.floor() as i64;
    if wl % 2 == 0 {
        wl -= 1;
    }
    let wu = wl + 2;
    let wlf = wl as f64;
    let m = ((12.0 * sigma * sigma - n * wlf * wlf - 4.0 * n * wlf - 3.0 * n) / (-4.0 * wlf - 4.0)).round() as i64;
    let mut out = [0usize; 3];
    for (i, o) in out.iter_mut().enumerate() {
        let size = if (i as i64) < m { wl } else { wu };
        *o = ((size.max(1) - 1) / 2) as usize;
    }
    out
}

/// Gaussian blur of a `w` x `h` buffer of `N`-channel pixels. `clamp`:
/// beyond the edges is the edge pixel (else transparent zero).
fn blur<const N: usize>(buf: &mut [[f32; N]], w: usize, h: usize, sigma: f64, clamp: bool) {
    if sigma < 0.3 || w == 0 || h == 0 {
        return;
    }
    for r in box_radii(sigma) {
        if r == 0 {
            continue;
        }
        box_rows(buf, w, h, r, clamp);
        transpose_box(buf, w, h, r, clamp);
    }
}

fn box_line<const N: usize>(src: &[[f32; N]], dst: &mut [[f32; N]], r: usize, clamp: bool) {
    let n = src.len() as i64;
    let get = |i: i64| -> [f32; N] {
        if i < 0 {
            if clamp { src[0] } else { [0.0; N] }
        } else if i >= n {
            if clamp { src[(n - 1) as usize] } else { [0.0; N] }
        } else {
            src[i as usize]
        }
    };
    let norm = 1.0 / (2 * r + 1) as f32;
    let mut sum = [0f32; N];
    for i in -(r as i64)..=(r as i64) {
        let p = get(i);
        for c in 0..N {
            sum[c] += p[c];
        }
    }
    for (i, d) in dst.iter_mut().enumerate() {
        for c in 0..N {
            d[c] = sum[c] * norm;
        }
        let add = get(i as i64 + r as i64 + 1);
        let sub = get(i as i64 - r as i64);
        for c in 0..N {
            sum[c] += add[c] - sub[c];
        }
    }
}

fn box_rows<const N: usize>(buf: &mut [[f32; N]], w: usize, _h: usize, r: usize, clamp: bool) {
    buf.par_chunks_mut(w).for_each(|row| {
        let src = row.to_vec();
        box_line(&src, row, r, clamp);
    });
}

fn transpose_box<const N: usize>(buf: &mut [[f32; N]], w: usize, h: usize, r: usize, clamp: bool) {
    let mut t = vec![[0f32; N]; w * h];
    for y in 0..h {
        for x in 0..w {
            t[x * h + y] = buf[y * w + x];
        }
    }
    t.par_chunks_mut(h).for_each(|col| {
        let src = col.to_vec();
        box_line(&src, col, r, clamp);
    });
    for x in 0..w {
        for y in 0..h {
            buf[y * w + x] = t[x * h + y];
        }
    }
}

// MARK: resampling

/// How output pixel `i` (of an axis) maps to the source: its centre lands at
/// `origin + (i + 0.5) * step` source pixels. Source pixels `lo..hi` exist;
/// beyond them is the edge pixel (`clamp`) or nothing.
#[derive(Debug, Clone, Copy)]
struct Axis {
    origin: f64,
    step: f64,
    lo: i64,
    hi: i64,
    clamp: bool,
    /// Plain bilinear even when shrinking (CoreImage's affine transforms).
    bilinear: bool,
}

struct Taps {
    /// Per output index: (first tap, weights).
    taps: Vec<(i64, Vec<f32>)>,
}

impl Axis {
    /// Shrinking by more than 0.75: Lanczos 3 (as the Mac's CILanczosScaleTransform);
    /// otherwise bilinear.
    fn taps(&self, n: usize) -> Taps {
        let scale = self.step.abs();
        let lanczos = scale > 1.0 / 0.75 && !self.bilinear;
        let support = if lanczos { 3.0 * scale } else { 1.0 };
        let taps = (0..n)
            .map(|i| {
                let s = self.origin + (i as f64 + 0.5) * self.step;
                let j0 = (s - support - 0.5).floor() as i64;
                let j1 = (s + support - 0.5).ceil() as i64;
                let mut ws: Vec<f32> = (j0..=j1)
                    .map(|j| {
                        let d = (j as f64 + 0.5 - s) / if lanczos { scale } else { 1.0 };
                        let w = if lanczos { lanczos3(d) } else { (1.0 - d.abs()).max(0.0) };
                        w as f32
                    })
                    .collect();
                let sum: f32 = ws.iter().sum();
                if sum.abs() > 1e-9 {
                    for w in ws.iter_mut() {
                        *w /= sum;
                    }
                }
                (j0, ws)
            })
            .collect();
        Taps { taps }
    }

    #[inline]
    fn index(&self, j: i64) -> Option<i64> {
        if j >= self.lo && j < self.hi {
            Some(j)
        } else if self.clamp && self.hi > self.lo {
            Some(j.clamp(self.lo, self.hi - 1))
        } else {
            None
        }
    }

    /// Source rows/columns the taps touch.
    fn range(&self, t: &Taps) -> (i64, i64) {
        let mut lo = i64::MAX;
        let mut hi = i64::MIN;
        for (j0, ws) in &t.taps {
            for k in 0..ws.len() as i64 {
                if let Some(j) = self.index(j0 + k) {
                    lo = lo.min(j);
                    hi = hi.max(j + 1);
                }
            }
        }
        if lo > hi { (0, 0) } else { (lo, hi) }
    }
}

fn lanczos3(x: f64) -> f64 {
    if x == 0.0 {
        return 1.0;
    }
    if x.abs() >= 3.0 {
        return 0.0;
    }
    let px = std::f64::consts::PI * x;
    3.0 * px.sin() * (px / 3.0).sin() / (px * px)
}

/// Separable resample: `out_w` x `out_h` pixels from `sample(x, y)` (premultiplied linear RGBA).
fn resample<F>(out_w: usize, out_h: usize, ax: Axis, ay: Axis, sample: F) -> Vec<[f32; 4]>
where
    F: Fn(i64, i64) -> [f32; 4] + Sync,
{
    if out_w == 0 || out_h == 0 {
        return vec![];
    }
    let tx = ax.taps(out_w);
    let ty = ay.taps(out_h);
    let (ry0, ry1) = ay.range(&ty);
    let rows = (ry1 - ry0).max(0) as usize;
    // Horizontal pass over the rows the vertical pass needs.
    let mut mid = vec![[0f32; 4]; rows * out_w];
    mid.par_chunks_mut(out_w).enumerate().for_each(|(r, line)| {
        let y = ry0 + r as i64;
        for (i, out) in line.iter_mut().enumerate() {
            let (j0, ws) = &tx.taps[i];
            let mut acc = [0f32; 4];
            for (k, w) in ws.iter().enumerate() {
                if let Some(x) = ax.index(j0 + k as i64) {
                    let p = sample(x, y);
                    for c in 0..4 {
                        acc[c] += p[c] * w;
                    }
                }
            }
            *out = acc;
        }
    });
    let mut out = vec![[0f32; 4]; out_w * out_h];
    out.par_chunks_mut(out_w).enumerate().for_each(|(o, line)| {
        let (j0, ws) = &ty.taps[o];
        for (k, w) in ws.iter().enumerate() {
            if let Some(y) = ay.index(j0 + k as i64) {
                let r = (y - ry0) as usize;
                let src = &mid[r * out_w..(r + 1) * out_w];
                for (d, s) in line.iter_mut().zip(src) {
                    for c in 0..4 {
                        d[c] += s[c] * w;
                    }
                }
            }
        }
    });
    out
}

/// Samples an sRGB RGBA8 image as premultiplied linear RGBA.
fn rgba8_sampler(img: &Rgba8) -> impl Fn(i64, i64) -> [f32; 4] + Sync + '_ {
    let lut = to_linear_lut();
    let w = img.width as i64;
    move |x, y| {
        let i = ((y * w + x) * 4) as usize;
        let p = &img.data[i..i + 4];
        let a = p[3] as f32 / 255.0;
        [lut[p[0] as usize] * a, lut[p[1] as usize] * a, lut[p[2] as usize] * a, a]
    }
}

/// Samples an sRGB RGBA8 image as its own (gamma) values, 0...1, opaque.
fn rgba8_gamma_sampler(img: &Rgba8) -> impl Fn(i64, i64) -> [f32; 4] + Sync + '_ {
    let w = img.width as i64;
    move |x, y| {
        let i = ((y * w + x) * 4) as usize;
        let p = &img.data[i..i + 4];
        [p[0] as f32 / 255.0, p[1] as f32 / 255.0, p[2] as f32 / 255.0, 1.0]
    }
}

const LIN_N: usize = 4096;
fn to_linear_fine_lut() -> &'static [f32] {
    static LUT: OnceLock<Vec<f32>> = OnceLock::new();
    LUT.get_or_init(|| (0..=LIN_N).map(|i| decode(i as f32 / LIN_N as f32)).collect())
}

/// Resamples an opaque 8-bit image in its own gamma space, then to linear:
/// how CoreImage samples an 8-bit image through an affine transform.
fn resample_gamma(out_w: usize, out_h: usize, ax: Axis, ay: Axis, img: &Rgba8) -> Vec<[f32; 4]> {
    let mut l = resample(out_w, out_h, ax, ay, rgba8_gamma_sampler(img));
    let lut = to_linear_fine_lut();
    l.par_iter_mut().for_each(|p| {
        for c in 0..3 {
            p[c] = lut[(p[c].clamp(0.0, 1.0) * LIN_N as f32 + 0.5) as usize];
        }
        p[3] = 1.0;
    });
    l
}

// MARK: hides (into the raw source frame)

fn apply_hides(src: &mut Rgba8, plan: &FramePlan) {
    let (w, h) = (src.width as usize, src.height as usize);
    // The plan is in meta pixels; the decoded frame should be the same size.
    let (kx, ky) = (w as f64 / plan.source.width.max(1) as f64, h as f64 / plan.source.height.max(1) as f64);
    let lut = to_linear_lut();
    for hide in &plan.source.hides {
        let r = Rect::new(hide.rect.x * kx, hide.rect.y * ky, hide.rect.w * kx, hide.rect.h * ky);
        let (x0, y0, x1, y1) = pixel_box(&r, w, h);
        let (rw, rh) = (x1 - x0, y1 - y0);
        if rw == 0 || rh == 0 {
            continue;
        }
        let mut region: Vec<[f32; 3]> = Vec::with_capacity(rw * rh);
        for y in y0..y1 {
            for x in x0..x1 {
                let i = (y * w + x) * 4;
                region.push([lut[src.data[i] as usize], lut[src.data[i + 1] as usize], lut[src.data[i + 2] as usize]]);
            }
        }
        match hide.style {
            HideStyle::Blur => {
                // Its own pixels only (edges extended), a wide pass then a softer one.
                blur(&mut region, rw, rh, hide.sigma * kx, true);
                blur(&mut region, rw, rh, hide.sigma * kx * 0.5, true);
            }
            HideStyle::Pixelate => {
                let cell = (hide.cell * kx).max(1.0);
                let at = |fx: f64, fy: f64| -> [f32; 3] {
                    // Bilinear at a point, clamped to the box.
                    let fx = (fx - 0.5).clamp(0.0, (rw - 1) as f64);
                    let fy = (fy - 0.5).clamp(0.0, (rh - 1) as f64);
                    let (ix, iy) = (fx.floor() as usize, fy.floor() as usize);
                    let (jx, jy) = ((ix + 1).min(rw - 1), (iy + 1).min(rh - 1));
                    let (ax, ay) = ((fx - ix as f64) as f32, (fy - iy as f64) as f32);
                    let p = |x: usize, y: usize| region[y * rw + x];
                    let mut o = [0f32; 3];
                    for c in 0..3 {
                        let top = p(ix, iy)[c] * (1.0 - ax) + p(jx, iy)[c] * ax;
                        let bot = p(ix, jy)[c] * (1.0 - ax) + p(jx, jy)[c] * ax;
                        o[c] = top * (1.0 - ay) + bot * ay;
                    }
                    o
                };
                let mut out = region.clone();
                let (nx, ny) = ((rw as f64 / cell).ceil() as usize, (rh as f64 / cell).ceil() as usize);
                for cy in 0..ny {
                    for cx in 0..nx {
                        let col = at((cx as f64 + 0.5) * cell, (cy as f64 + 0.5) * cell);
                        let (px0, py0) = ((cx as f64 * cell) as usize, (cy as f64 * cell) as usize);
                        let (px1, py1) = ((((cx + 1) as f64 * cell) as usize).min(rw), (((cy + 1) as f64 * cell) as usize).min(rh));
                        for y in py0..py1 {
                            for x in px0..px1 {
                                out[y * rw + x] = col;
                            }
                        }
                    }
                }
                region = out;
            }
            HideStyle::Solid => {
                let c = lin(&hide.color);
                region.iter_mut().for_each(|p| *p = c);
            }
        }
        for y in y0..y1 {
            for x in x0..x1 {
                let p = region[(y - y0) * rw + (x - x0)];
                let i = (y * w + x) * 4;
                src.data[i] = enc8(p[0]);
                src.data[i + 1] = enc8(p[1]);
                src.data[i + 2] = enc8(p[2]);
            }
        }
    }
}

// MARK: backdrop

/// A still per-pixel noise in [0, 1), the same every frame.
#[inline]
fn grain_noise(x: usize, y: usize) -> f32 {
    let mut h = (x as u32).wrapping_mul(0x8DA6_B343) ^ (y as u32).wrapping_mul(0xD816_3841) ^ 0x9E37_79B9;
    h ^= h >> 15;
    h = h.wrapping_mul(0x2C1B_3C6D);
    h ^= h >> 12;
    h = h.wrapping_mul(0x297A_2D39);
    h ^= h >> 15;
    (h >> 8) as f32 / (1u32 << 24) as f32
}

fn paint_backdrop(plan: &BackdropPlan, w: usize, h: usize, folder: Option<&Path>) -> Vec<[f32; 3]> {
    let mut out = vec![[0f32; 3]; w * h];
    let grain = |out: &mut [[f32; 3]], g: f64| {
        if g <= 0.0 {
            return;
        }
        let g = g as f32;
        out.par_chunks_mut(w).enumerate().for_each(|(y, row)| {
            for (x, p) in row.iter_mut().enumerate() {
                let m = 1.0 - g + g * grain_noise(x, y);
                for c in p.iter_mut() {
                    *c *= m;
                }
            }
        });
    };
    match plan {
        BackdropPlan::Solid { color, grain: g } => {
            let c = lin(color);
            out.iter_mut().for_each(|p| *p = c);
            grain(&mut out, *g);
        }
        BackdropPlan::Linear { from, to, color_from, color_to, grain: g } => {
            let (a, b) = (lin(color_from), lin(color_to));
            let (dx, dy) = (to.x - from.x, to.y - from.y);
            let len2 = (dx * dx + dy * dy).max(1e-9);
            out.par_chunks_mut(w).enumerate().for_each(|(y, row)| {
                for (x, p) in row.iter_mut().enumerate() {
                    let t = (((x as f64 + 0.5 - from.x) * dx + (y as f64 + 0.5 - from.y) * dy) / len2).clamp(0.0, 1.0) as f32;
                    for c in 0..3 {
                        p[c] = a[c] + (b[c] - a[c]) * t;
                    }
                }
            });
            grain(&mut out, *g);
        }
        BackdropPlan::Image { file, blur_sigma, fallback } => {
            let img = folder.and_then(|f| image::open(f.join(file)).ok()).map(|i| i.to_rgba8());
            let Some(img) = img else { return paint_backdrop(fallback, w, h, folder) };
            let pic = Rgba8::new(img.width(), img.height(), img.into_raw());
            // Fill the canvas (cover), centred.
            let (iw, ih) = (pic.width as f64, pic.height as f64);
            let k = (w as f64 / iw).max(h as f64 / ih);
            let ax = Axis { origin: (iw - w as f64 / k) / 2.0, step: 1.0 / k, lo: 0, hi: pic.width as i64, clamp: true, bilinear: true };
            let ay = Axis { origin: (ih - h as f64 / k) / 2.0, step: 1.0 / k, lo: 0, hi: pic.height as i64, clamp: true, bilinear: true };
            let px = resample_gamma(w, h, ax, ay, &pic);
            for (o, p) in out.iter_mut().zip(px) {
                *o = [p[0], p[1], p[2]];
            }
            if *blur_sigma > 0.0 {
                blur(&mut out, w, h, *blur_sigma, true);
            }
        }
    }
    out
}

// MARK: the painter

/// A blurred rounded-rect alpha, cached (shadows are the same every frame).
#[derive(Clone)]
struct ShadowMask {
    key: ShadowKey,
    x0: usize,
    y0: usize,
    w: usize,
    h: usize,
    alpha: Vec<[f32; 1]>,
}

fn shadow_mask(rect: &Rect, radius: f64, sigma: f64, cw: usize, ch: usize) -> ShadowMask {
    let pad = 3.0 * sigma + 2.0;
    let area = Rect::new(rect.x - pad, rect.y - pad, rect.w + 2.0 * pad, rect.h + 2.0 * pad);
    let (x0, y0, x1, y1) = pixel_box(&area, cw, ch);
    // Blur over the unclipped area so the canvas edge doesn't cut the falloff.
    let (ux0, uy0) = (area.x.floor() as i64, area.y.floor() as i64);
    let (uw, uh) = ((area.max_x().ceil() as i64 - ux0).max(0) as usize, (area.max_y().ceil() as i64 - uy0).max(0) as usize);
    let mut a = vec![[0f32; 1]; uw * uh];
    for y in 0..uh {
        for x in 0..uw {
            a[y * uw + x] = [rounded_cov(rect, radius, (ux0 + x as i64) as f64 + 0.5, (uy0 + y as i64) as f64 + 0.5)];
        }
    }
    blur(&mut a, uw, uh, sigma, false);
    let (w, h) = (x1 - x0, y1 - y0);
    let mut alpha = vec![[0f32; 1]; w * h];
    for y in 0..h {
        for x in 0..w {
            let (sx, sy) = (x0 as i64 + x as i64 - ux0, y0 as i64 + y as i64 - uy0);
            alpha[y * w + x] = a[sy as usize * uw + sx as usize];
        }
    }
    ShadowMask { key: shadow_key(rect, radius, sigma), x0, y0, w, h, alpha }
}

type ShadowKey = (i64, i64, i64, i64, i64, i64);

fn shadow_key(rect: &Rect, radius: f64, sigma: f64) -> ShadowKey {
    let q = |v: f64| (v * 64.0).round() as i64;
    (q(rect.x), q(rect.y), q(rect.w), q(rect.h), q(radius), q(sigma))
}

fn super_lin(c: &Rgba) -> [f32; 3] {
    lin(c)
}

struct Base {
    key: Option<ShadowKey>,
    lin: Vec<[f32; 3]>,
    enc: Vec<u8>,
}

struct Sprite {
    key: (String, String, String, u32),
    w: usize,
    h: usize,
    tip: (f64, f64),
    px: Vec<[f32; 4]>,
}

/// Draws FramePlans for one edit. Keeps what doesn't change between frames
/// (backdrop, shadows, cursor sprite).
pub struct Painter {
    width: usize,
    height: usize,
    backdrop: Vec<[f32; 3]>,
    shadows: Vec<ShadowMask>,
    bases: Vec<Base>,
    sprite: Option<Sprite>,
    folder: Option<PathBuf>,
}

impl Painter {
    /// `folder` is the .reel folder (for an image backdrop).
    pub fn new(planner: &Planner, folder: Option<&Path>) -> Painter {
        let (w, h) = (planner.canvas.width as usize, planner.canvas.height as usize);
        Painter {
            width: w,
            height: h,
            backdrop: paint_backdrop(&planner.backdrop, w, h, folder),
            shadows: vec![],
            bases: vec![],
            sprite: None,
            folder: folder.map(Path::to_path_buf),
        }
    }

    pub fn size(&self) -> (u32, u32) {
        (self.width as u32, self.height as u32)
    }

    pub fn folder(&self) -> Option<&Path> {
        self.folder.as_deref()
    }

    fn shadow(&mut self, rect: &Rect, radius: f64, sigma: f64) -> &ShadowMask {
        let key = shadow_key(rect, radius, sigma);
        if let Some(i) = self.shadows.iter().position(|s| s.key == key) {
            return &self.shadows[i];
        }
        if self.shadows.len() >= 8 {
            self.shadows.remove(0);
        }
        self.shadows.push(shadow_mask(rect, radius, sigma, self.width, self.height));
        self.shadows.last().unwrap()
    }

    /// Backdrop with the frame's shadow on it: the same for every frame of a
    /// take, kept in linear light and encoded.
    fn base(&mut self, plan: &FramePlan) -> usize {
        let key = plan.shadow.as_ref().map(|s| shadow_key(&s.rect, s.radius, s.sigma));
        if let Some(i) = self.bases.iter().position(|b| b.key == key) {
            return i;
        }
        let mut lin = self.backdrop.clone();
        if let Some(s) = &plan.shadow {
            let col = super_lin(&s.color);
            let a = s.color.a as f32;
            let m = self.shadow(&s.rect, s.radius, s.sigma).clone();
            composite_mask(&mut lin, self.width, &m, col, a);
        }
        let mut enc = vec![255u8; lin.len() * 4];
        enc.par_chunks_mut(self.width * 4).zip(lin.par_chunks(self.width)).for_each(|(out, row)| {
            for (o, p) in out.chunks_mut(4).zip(row) {
                o[0] = enc8(p[0]);
                o[1] = enc8(p[1]);
                o[2] = enc8(p[2]);
            }
        });
        if self.bases.len() >= 4 {
            self.bases.remove(0);
        }
        self.bases.push(Base { key, lin, enc });
        self.bases.len() - 1
    }

    fn sprite(&mut self, style: &str, tint: &str, label: &str, height: u32) -> &Sprite {
        let key = (style.to_string(), tint.to_string(), label.to_string(), height);
        if self.sprite.as_ref().map(|s| &s.key) != Some(&key) {
            let a = cursor_art(&CursorStyle::parse(style), &CursorTint::parse(tint), label, height);
            let lut = to_linear_lut();
            let px = a
                .rgba
                .chunks(4)
                .map(|p| {
                    let al = p[3] as f32 / 255.0;
                    if al <= 0.0 {
                        return [0.0; 4];
                    }
                    let un = |v: u8| lut[((v as f32 / al).round().min(255.0)) as usize];
                    [un(p[0]) * al, un(p[1]) * al, un(p[2]) * al, al]
                })
                .collect();
            self.sprite = Some(Sprite { key, w: a.width as usize, h: a.height as usize, tip: (a.tip_x, a.tip_y), px });
        }
        self.sprite.as_ref().unwrap()
    }

    /// Draws `plan`. `source` is the take's frame at `plan.take_time`;
    /// `webcam` the frame of the first webcam candidate that has one, with
    /// its index in `plan.webcam`.
    pub fn paint(&mut self, plan: &FramePlan, source: &Rgba8, webcam: Option<(usize, &Rgba8)>) -> Rgba8 {
        let (cw, ch) = (self.width, self.height);
        let prof = std::env::var_os("MONETSHOT_PROFILE").is_some();
        let t0 = std::time::Instant::now();
        let lap = |what: &str| {
            if prof {
                eprintln!("  {what}: {:.1} ms", t0.elapsed().as_secs_f64() * 1000.0);
            }
        };
        // Backdrop and the frame's shadow (cached), already encoded.
        let bi = self.base(plan);
        let mut data = self.bases[bi].enc.clone();
        lap("base");

        // Hidden boxes go into (a copy of) the raw frame.
        let hidden;
        let source = if plan.source.hides.is_empty() {
            source
        } else {
            let mut s = source.clone();
            apply_hides(&mut s, plan);
            hidden = s;
            &hidden
        };
        lap("hides");

        // The recording, with ripples and the cursor, in a layer the frame's size.
        let f = plan.frame;
        let (fx0, fy0, fx1, fy1) = pixel_box(&f, cw, ch);
        let (fw, fh) = (fx1 - fx0, fy1 - fy0);
        if fw > 0 && fh > 0 {
            let (kx, ky) = (source.width as f64 / plan.source.width.max(1) as f64, source.height as f64 / plan.source.height.max(1) as f64);
            let b = &plan.source.bounds;
            let r = &plan.source.rect;
            let ax = Axis {
                origin: r.x * kx + (fx0 as f64 - f.x) * (r.w * kx / f.w),
                step: r.w * kx / f.w,
                lo: (b.x * kx).round() as i64,
                hi: ((b.x + b.w) * kx).round() as i64,
                clamp: true,
                bilinear: false,
            };
            let ay = Axis {
                origin: r.y * ky + (fy0 as f64 - f.y) * (r.h * ky / f.h),
                step: r.h * ky / f.h,
                lo: (b.y * ky).round() as i64,
                hi: ((b.y + b.h) * ky).round() as i64,
                clamp: true,
                bilinear: false,
            };
            // CoreImage filters a big shrink (Lanczos) in linear light, but
            // samples an 8-bit source bilinearly in its own (gamma) space.
            let mut layer =
                if plan.source.lanczos { resample(fw, fh, ax, ay, rgba8_sampler(source)) } else { resample_gamma(fw, fh, ax, ay, source) };
            lap("source");

            for rp in &plan.ripples {
                let col = lin(&rp.color);
                let area = Rect::new(rp.center.x - rp.radius, rp.center.y - rp.radius, rp.radius * 2.0, rp.radius * 2.0);
                let (x0, y0, x1, y1) = pixel_box(&area, cw, ch);
                for y in y0.max(fy0)..y1.min(fy1) {
                    for x in x0.max(fx0)..x1.min(fx1) {
                        let d = ((x as f64 + 0.5 - rp.center.x).powi(2) + (y as f64 + 0.5 - rp.center.y).powi(2)).sqrt();
                        let a = (rp.alpha * monetshot_core::plan::ripple_profile(d, rp.radius)) as f32;
                        if a > 0.0 {
                            let p = &mut layer[(y - fy0) * fw + (x - fx0)];
                            for c in 0..3 {
                                p[c] = col[c] * a + p[c] * (1.0 - a);
                            }
                        }
                    }
                }
            }

            if let Some(cur) = &plan.cursor {
                let s = cur.height / cur.art_height.max(1) as f64;
                let sprite = self.sprite(&cur.style, &cur.tint, &cur.label, cur.art_height);
                let (sx0, sy0) = (cur.tip.x - sprite.tip.0 * s, cur.tip.y - sprite.tip.1 * s);
                let area = Rect::new(sx0, sy0, sprite.w as f64 * s, sprite.h as f64 * s);
                let (x0, y0, x1, y1) = pixel_box(&area, cw, ch);
                let (x0, y0, x1, y1) = (x0.max(fx0), y0.max(fy0), x1.min(fx1), y1.min(fy1));
                if x1 > x0 && y1 > y0 {
                    let ax = Axis { origin: (x0 as f64 - sx0) / s, step: 1.0 / s, lo: 0, hi: sprite.w as i64, clamp: false, bilinear: false };
                    let ay = Axis { origin: (y0 as f64 - sy0) / s, step: 1.0 / s, lo: 0, hi: sprite.h as i64, clamp: false, bilinear: false };
                    let sw = sprite.w as i64;
                    let px = &sprite.px;
                    let art = resample(x1 - x0, y1 - y0, ax, ay, |x, y| px[(y * sw + x) as usize]);
                    for y in y0..y1 {
                        for x in x0..x1 {
                            let a = art[(y - y0) * (x1 - x0) + (x - x0)];
                            let p = &mut layer[(y - fy0) * fw + (x - fx0)];
                            let inv = 1.0 - a[3].clamp(0.0, 1.0);
                            for c in 0..3 {
                                p[c] = a[c].max(0.0) + p[c] * inv;
                            }
                        }
                    }
                }
            }
            lap("ripples+cursor");

            // Onto the base through the rounded corners, encoded as we go.
            let radius = plan.corner_radius;
            let base = &self.bases[bi].lin;
            data[fy0 * cw * 4..fy1 * cw * 4].par_chunks_mut(cw * 4).enumerate().for_each(|(ry, row)| {
                let y = fy0 + ry;
                for x in fx0..fx1 {
                    let cov = if radius > 0.0 { rounded_cov(&f, radius, x as f64 + 0.5, y as f64 + 0.5) } else { 1.0 };
                    if cov <= 0.0 {
                        continue;
                    }
                    let l = layer[ry * fw + (x - fx0)];
                    let under = base[y * cw + x];
                    let o = &mut row[x * 4..x * 4 + 3];
                    for c in 0..3 {
                        o[c] = enc8(l[c] * cov + under[c] * (1.0 - cov));
                    }
                }
            });
        }
        lap("frame");

        // You on camera.
        if let Some((i, cam)) = webcam {
            if let Some(wp) = plan.webcam.get(i) {
                self.paint_webcam(&mut data, wp, cam);
            }
        }
        lap("webcam");
        Rgba8::new(cw as u32, ch as u32, data)
    }

    fn paint_webcam(&mut self, data: &mut [u8], wp: &WebcamPlan, cam: &Rgba8) {
        if wp.opacity <= 0.001 {
            return;
        }
        let (cw, ch) = (self.width, self.height);
        let r = wp.rect;
        // The group's area: face, rim and shadow.
        let mut area = r;
        if let Some(rim) = &wp.rim {
            area = union(&area, &rim.rect);
        }
        if let Some(s) = &wp.shadow {
            let p = 3.0 * s.sigma + 2.0;
            area = union(&area, &Rect::new(s.rect.x - p, s.rect.y - p, s.rect.w + 2.0 * p, s.rect.h + 2.0 * p));
        }
        let (x0, y0, x1, y1) = pixel_box(&area, cw, ch);
        let (gw, gh) = (x1 - x0, y1 - y0);
        if gw == 0 || gh == 0 {
            return;
        }
        let mut group = vec![[0f32; 4]; gw * gh];
        let over = |dst: &mut [f32; 4], src: [f32; 4]| {
            let inv = 1.0 - src[3];
            for c in 0..4 {
                dst[c] = src[c] + dst[c] * inv;
            }
        };
        if let Some(s) = &wp.shadow {
            let m = self.shadow(&s.rect, s.radius, s.sigma).clone();
            let col = lin(&s.color);
            for my in 0..m.h {
                for mx in 0..m.w {
                    let (x, y) = (m.x0 + mx, m.y0 + my);
                    if x < x0 || x >= x1 || y < y0 || y >= y1 {
                        continue;
                    }
                    let a = m.alpha[my * m.w + mx][0] * s.color.a as f32;
                    over(&mut group[(y - y0) * gw + (x - x0)], [col[0] * a, col[1] * a, col[2] * a, a]);
                }
            }
        }
        if let Some(rim) = &wp.rim {
            let col = lin(&rim.color);
            let a0 = rim.color.a as f32;
            for y in y0..y1 {
                for x in x0..x1 {
                    let a = rounded_cov(&rim.rect, rim.radius, x as f64 + 0.5, y as f64 + 0.5) * a0;
                    if a > 0.0 {
                        over(&mut group[(y - y0) * gw + (x - x0)], [col[0] * a, col[1] * a, col[2] * a, a]);
                    }
                }
            }
        }
        // The face: the camera picture filling `rect` (cover), maybe mirrored.
        let (fx0, fy0, fx1, fy1) = pixel_box(&r, cw, ch);
        let (iw, ih) = (cam.width as f64, cam.height as f64);
        let k = (r.w / iw).max(r.h / ih);
        let (mx, my) = (r.x + r.w / 2.0, r.y + r.h / 2.0);
        let ax = if wp.mirror {
            Axis { origin: iw / 2.0 - (fx0 as f64 - mx) / k, step: -1.0 / k, lo: 0, hi: cam.width as i64, clamp: true, bilinear: true }
        } else {
            Axis { origin: iw / 2.0 + (fx0 as f64 - mx) / k, step: 1.0 / k, lo: 0, hi: cam.width as i64, clamp: true, bilinear: true }
        };
        let ay = Axis { origin: ih / 2.0 + (fy0 as f64 - my) / k, step: 1.0 / k, lo: 0, hi: cam.height as i64, clamp: true, bilinear: true };
        let face = resample_gamma(fx1 - fx0, fy1 - fy0, ax, ay, cam);
        for y in fy0..fy1 {
            for x in fx0..fx1 {
                let cov = if wp.radius > 0.0 { rounded_cov(&r, wp.radius, x as f64 + 0.5, y as f64 + 0.5) } else { cov_rect(&r, x, y) };
                if cov <= 0.0 || x < x0 || y < y0 || x >= x1 || y >= y1 {
                    continue;
                }
                let p = face[(y - fy0) * (fx1 - fx0) + (x - fx0)];
                over(&mut group[(y - y0) * gw + (x - x0)], p.map(|v| v * cov));
            }
        }
        let o = wp.opacity as f32;
        let lut = to_linear_lut();
        for y in y0..y1 {
            for x in x0..x1 {
                let g = group[(y - y0) * gw + (x - x0)];
                let a = g[3] * o;
                if a <= 0.0 {
                    continue;
                }
                let p = &mut data[(y * cw + x) * 4..(y * cw + x) * 4 + 3];
                for c in 0..3 {
                    p[c] = enc8(g[c] * o + lut[p[c] as usize] * (1.0 - a));
                }
            }
        }
    }
}

fn cov_rect(r: &Rect, x: usize, y: usize) -> f32 {
    let ox = ((x as f64 + 1.0).min(r.max_x()) - (x as f64).max(r.x)).clamp(0.0, 1.0);
    let oy = ((y as f64 + 1.0).min(r.max_y()) - (y as f64).max(r.y)).clamp(0.0, 1.0);
    (ox * oy) as f32
}

fn union(a: &Rect, b: &Rect) -> Rect {
    let x0 = a.x.min(b.x);
    let y0 = a.y.min(b.y);
    Rect::new(x0, y0, a.max_x().max(b.max_x()) - x0, a.max_y().max(b.max_y()) - y0)
}

fn composite_mask(canvas: &mut [[f32; 3]], cw: usize, m: &ShadowMask, col: [f32; 3], alpha: f32) {
    for y in 0..m.h {
        let row = &mut canvas[(m.y0 + y) * cw + m.x0..(m.y0 + y) * cw + m.x0 + m.w];
        for (x, p) in row.iter_mut().enumerate() {
            let a = m.alpha[y * m.w + x][0] * alpha;
            for c in 0..3 {
                p[c] = col[c] * a + p[c] * (1.0 - a);
            }
        }
    }
}

/// Shrinks an image to `width` (keeping its aspect), filtered.
pub fn shrink(img: &Rgba8, width: u32) -> Rgba8 {
    if width >= img.width {
        return img.clone();
    }
    let height = ((img.height as f64 * width as f64 / img.width as f64) as u32).max(1);
    let ax = Axis { origin: 0.0, step: img.width as f64 / width as f64, lo: 0, hi: img.width as i64, clamp: true, bilinear: false };
    let ay = Axis { origin: 0.0, step: img.height as f64 / height as f64, lo: 0, hi: img.height as i64, clamp: true, bilinear: false };
    let px = resample(width as usize, height as usize, ax, ay, rgba8_sampler(img));
    let mut data = Vec::with_capacity(px.len() * 4);
    for p in px {
        let a = p[3].clamp(0.0, 1.0);
        let un = |v: f32| if a > 0.0 { enc8(v / a) } else { 0 };
        data.extend_from_slice(&[un(p[0]), un(p[1]), un(p[2]), (a * 255.0 + 0.5) as u8]);
    }
    Rgba8::new(width, height, data)
}
