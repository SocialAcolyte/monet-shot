//! The FramePlan: everything about one finished frame at output time `t`,
//! decided once here and drawn by two thin painters (the WebGL preview and
//! the tiny-skia export). A port of `Render/Renderer.swift` with CoreImage's
//! bottom-left origin turned into top-left canvas pixels.
//! Contract: `docs/porting/contracts/frame-plan.md`.

use crate::camera::{self, CameraCorner, CameraShape};
use crate::camera_math::{self, Camera, SmoothTrack};
use crate::cursor::POINT_HEIGHT;
use crate::model::{Backdrop, CursorSample, CursorTrack, EditDoc, RecordingMeta, ZoomSegment};
use crate::privacy::{BlurRegion, BlurStyle, NormRect};
use crate::project::Project;
use crate::text::text_motion;
use crate::timemap::TimeMap;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub fn new(x: f64, y: f64, w: f64, h: f64) -> Rect {
        Rect { x, y, w, h }
    }
    pub fn max_x(&self) -> f64 {
        self.x + self.w
    }
    pub fn max_y(&self) -> f64 {
        self.y + self.h
    }
    pub fn inset(&self, d: f64) -> Rect {
        Rect { x: self.x + d, y: self.y + d, w: self.w - 2.0 * d, h: self.h - 2.0 * d }
    }
    /// CoreGraphics `.integral`: the smallest whole-pixel rect containing it.
    pub fn integral(&self) -> Rect {
        let (x0, y0) = (self.x.floor(), self.y.floor());
        Rect { x: x0, y: y0, w: self.max_x().ceil() - x0, h: self.max_y().ceil() - y0 }
    }
    pub fn intersection(&self, o: &Rect) -> Rect {
        let x0 = self.x.max(o.x);
        let y0 = self.y.max(o.y);
        let x1 = self.max_x().min(o.max_x());
        let y1 = self.max_y().min(o.max_y());
        if x1 <= x0 || y1 <= y0 {
            return Rect::new(0.0, 0.0, 0.0, 0.0);
        }
        Rect { x: x0, y: y0, w: x1 - x0, h: y1 - y0 }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

/// sRGB-encoded, straight (not premultiplied) alpha, 0...1.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Rgba {
    pub r: f64,
    pub g: f64,
    pub b: f64,
    pub a: f64,
}

impl Rgba {
    pub fn hex(hex: u32, a: f64) -> Rgba {
        Rgba {
            r: ((hex >> 16) & 0xFF) as f64 / 255.0,
            g: ((hex >> 8) & 0xFF) as f64 / 255.0,
            b: (hex & 0xFF) as f64 / 255.0,
            a,
        }
    }
    pub fn new(r: f64, g: f64, b: f64, a: f64) -> Rgba {
        Rgba { r, g, b, a }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Size {
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum BackdropPlan {
    /// One colour over the canvas, darkened by grain (`grain` 0 = none).
    Solid { color: Rgba, grain: f64 },
    /// A linear gradient from `from` (colour `color_from`) to `to`,
    /// clamped beyond both ends, interpolated in linear light; then grain.
    Linear { from: Point, to: Point, color_from: Rgba, color_to: Rgba, grain: f64 },
    /// A picture filling the canvas (cover, centred), blurred by
    /// `blur_sigma` px with edges extended; `fallback` if it can't be read.
    Image { file: String, blur_sigma: f64, fallback: Box<BackdropPlan> },
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ShadowPlan {
    /// The rounded rect that casts it (already offset).
    pub rect: Rect,
    pub radius: f64,
    pub color: Rgba,
    /// Gaussian blur, px.
    pub sigma: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum HideStyle {
    Blur,
    Pixelate,
    Solid,
}

/// A hidden box drawn into the raw frame (source pixels) before anything else.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HidePlan {
    pub style: HideStyle,
    /// Whole source pixels, inside the frame.
    pub rect: Rect,
    /// Blur: first pass sigma (second pass is sigma / 2), px.
    pub sigma: f64,
    /// Pixelate: cell size, px; cells start at the rect's top-left.
    pub cell: f64,
    /// Solid: the cover colour.
    pub color: Rgba,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourcePlan {
    pub take: i64,
    /// The raw frame's size (meta.json).
    pub width: i64,
    pub height: i64,
    pub hides: Vec<HidePlan>,
    /// The take's crop in source pixels (whole pixels). Sampling clamps to
    /// its edges (edge colour beyond).
    pub bounds: Rect,
    /// The part of the source shown in `frame` (source pixels): map it
    /// straight onto `frame` (the scale is the same on both axes).
    pub rect: Rect,
    /// Shrinking by more than 0.75: downscale with a good filter (Lanczos /
    /// mipmaps) so fine text doesn't alias.
    pub lanczos: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CursorPlan {
    pub style: String,
    pub tint: String,
    pub label: String,
    /// The pixel height the art is rendered at (`cursorArt(..., artHeight)`).
    pub art_height: u32,
    /// Where the hotspot goes on the canvas.
    pub tip: Point,
    /// The arrow's height on the canvas, px: draw the art scaled by
    /// `height / artHeight`, hotspot on `tip`.
    pub height: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RipplePlan {
    pub center: Point,
    pub radius: f64,
    /// Peak alpha of the ring.
    pub alpha: f64,
    pub color: Rgba,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RimPlan {
    pub rect: Rect,
    pub radius: f64,
    pub color: Rgba,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum WebcamKind {
    /// Recorded over the edit (`edit.cameraClips`).
    Overlay,
    /// Recorded with the take (`meta.camera`).
    Take,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WebcamPlan {
    pub kind: WebcamKind,
    /// Path relative to the .reel folder.
    pub file: String,
    /// Seconds into that file.
    pub time: f64,
    /// Fills the take's frame instead of sitting in a bubble.
    pub full: bool,
    /// Group opacity of everything below (face, rim, shadow). Draw nothing at <= 0.001.
    pub opacity: f64,
    /// Flip the camera picture left-right.
    pub mirror: bool,
    /// Cover-fit the camera picture into this rect, clipped to a rounded rect of `radius`.
    pub rect: Rect,
    pub radius: f64,
    pub rim: Option<RimPlan>,
    pub shadow: Option<ShadowPlan>,
}

/// Everything about the frame at output time `t`. Canvas pixels, origin top-left.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FramePlan {
    pub t: f64,
    pub canvas: Size,
    pub clip_index: usize,
    pub take: i64,
    pub take_time: f64,
    pub backdrop: BackdropPlan,
    pub shadow: Option<ShadowPlan>,
    /// Where the recording sits.
    pub frame: Rect,
    /// Round the frame's corners (content, cursor and ripples) by this; 0 = square.
    pub corner_radius: f64,
    pub source: SourcePlan,
    /// The zoom, in the cropped picture's 0...1 coordinates.
    pub camera: Camera,
    pub ripples: Vec<RipplePlan>,
    pub cursor: Option<CursorPlan>,
    /// Candidates in priority order: draw the first whose file has a frame
    /// at `time` (and nothing if that one's opacity is ~0).
    pub webcam: Vec<WebcamPlan>,
    /// A clip fading in or out: draw the backdrop once more over everything
    /// at this opacity (0 = no fade). Text overlays go on top of it.
    pub veil: f64,
    /// The clip's playback speed (take seconds per output second): a
    /// preview playing the take's video runs it at this rate.
    pub speed: f64,
    /// Words on top of everything (the veil too), in drawing order.
    pub texts: Vec<TextPlan>,
}

/// One text: draw the picture `text_art(plan)` makes (the export crate's,
/// in wasm as `textArt`) centred on `center`, scaled by `scale` about its
/// centre, at `opacity`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TextPlan {
    pub lines: Vec<String>,
    pub px: f64,
    pub tracking: f64,
    pub center: Point,
    pub opacity: f64,
    pub scale: f64,
    /// One alpha per word in reading order; empty = every word fully shown.
    pub words: Vec<f64>,
    pub color: Rgba,
    /// The box behind the words, if any (padding and radius: `text_motion`).
    pub backing: Option<Rgba>,
    /// A soft shadow under unboxed light words (in the picture).
    pub shadow: bool,
    /// The word being said (reading order) and its colour, in a caption.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub highlight: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub highlight_color: Option<Rgba>,
}

/// One take as the planner needs it.
#[derive(Debug, Clone)]
pub struct PlanTake {
    pub meta: RecordingMeta,
    pub cursor: CursorTrack,
    /// The take's folder relative to the .reel folder ("" for the first).
    pub dir: String,
}

/// Everything that depends on one take.
#[derive(Debug, Clone)]
struct Look {
    meta: RecordingMeta,
    dir: String,
    crop: NormRect,
    blurs: Vec<BlurRegion>,
    frame: Rect,
    px_per_point: f64,
    cursor_base_height: f64,
    has_cursor: bool,
    clicks: Vec<CursorSample>,
    cursor_track: SmoothTrack,
    focus_track: SmoothTrack,
    segments: Vec<ZoomSegment>,
    radius: f64,
    shadow: Option<ShadowPlan>,
}

/// Built once per edit (it smooths every take's pointer), then asked for
/// a plan at any `t` cheaply.
#[derive(Debug, Clone)]
pub struct Planner {
    pub doc: EditDoc,
    pub map: TimeMap,
    pub canvas: Size,
    pub backdrop: BackdropPlan,
    pub cursor_art_height: u32,
    looks: Vec<Look>,
    /// What was said, as captions (empty unless the edit shows them).
    pub captions: Vec<crate::text::TextOverlay>,
}

impl Planner {
    pub fn from_project(p: &Project) -> Planner {
        let takes: Vec<PlanTake> = p
            .takes
            .iter()
            .map(|t| PlanTake {
                meta: t.meta.clone(),
                cursor: t.cursor.clone(),
                dir: t
                    .folder
                    .strip_prefix(&p.folder)
                    .map(|d| d.to_string_lossy().replace('\\', "/"))
                    .unwrap_or_default(),
            })
            .collect();
        let planner = Planner::new(&p.edit, &takes);
        #[cfg(not(target_arch = "wasm32"))]
        let planner = planner.with_transcripts(&p.takes.iter().map(|t| crate::captions::Transcript::load(&t.folder)).collect::<Vec<_>>());
        planner
    }

    /// The captions for these transcripts (`transcripts[k]` is take k's),
    /// when the edit shows them.
    pub fn with_transcripts(mut self, transcripts: &[Option<crate::captions::Transcript>]) -> Planner {
        self.captions = if self.doc.captions == Some(true) {
            let anim = self.doc.format.as_deref().and_then(crate::formats::named).map_or(crate::text::TextAnimation::Words, |f| f.caption_animation.clone());
            crate::captions::overlays(transcripts, &self.map, self.canvas.width as f64, self.canvas.height as f64, anim)
        } else {
            vec![]
        };
        self
    }

    pub fn new(doc: &EditDoc, takes: &[PlanTake]) -> Planner {
        let first = takes.first().map(|t| t.meta.clone()).unwrap_or_else(|| {
            RecordingMeta::new(1920, 1080, 1.0, 1.0, Default::default(), "display", "screen.mov")
        });
        let map = TimeMap::new(doc, first.duration);
        let (cw, ch) = doc.canvas_size(first.aspect());
        let (cwf, chf) = (cw as f64, ch as f64);
        let short = cwf.min(chf);
        let backdrop_kind = doc.backdrop.known();
        let framed = backdrop_kind != Backdrop::None;
        let pad = if framed { doc.padding * short } else { 0.0 };
        let room = Rect::new(pad, pad, cwf - 2.0 * pad, chf - 2.0 * pad);
        let (room_mid_x, room_mid_y) = (room.x + room.w / 2.0, room.y + room.h / 2.0);

        let looks = takes
            .iter()
            .enumerate()
            .map(|(index, take)| {
                let meta = take.meta.clone();
                let crop = doc.crop(index as i64);
                let aspect = meta.aspect() * crop.w / crop.h;
                let (mut fw, mut fh) = (room.w, room.w / aspect);
                if fh > room.h {
                    fh = room.h;
                    fw = fh * aspect;
                }
                // CoreImage rounds the bottom-left corner; the room is centred,
                // so flipping keeps whole pixels.
                let (x, y_ci, w, h) = ((room_mid_x - fw / 2.0).round(), (room_mid_y - fh / 2.0).round(), fw.round(), fh.round());
                let frame = Rect::new(x, chf - y_ci - h, w, h);
                let ppp = frame.w / (meta.pixel_width as f64 * crop.w / meta.point_scale.max(1.0));
                let radius = if framed { doc.corner_radius * frame.w.min(frame.h) } else { 0.0 };
                let shadow = (framed && doc.shadow).then(|| {
                    let blur = 0.035 * short;
                    let alpha = if backdrop_kind == Backdrop::Paper { 0.30 } else { 0.55 };
                    ShadowPlan {
                        rect: Rect::new(frame.x, frame.y + blur * 0.45, frame.w, frame.h),
                        radius: radius.max(1.0),
                        color: Rgba::new(0.05, 0.04, 0.03, alpha),
                        sigma: blur,
                    }
                });
                let local = |s: &CursorSample| {
                    let p = crop.local(s.x, s.y);
                    CursorSample::new(s.t, p.0, p.1)
                };
                let samples: Vec<CursorSample> =
                    if crop.is_full() { take.cursor.samples.clone() } else { take.cursor.samples.iter().map(local).collect() };
                let clicks: Vec<CursorSample> =
                    if crop.is_full() { take.cursor.clicks.clone() } else { take.cursor.clicks.iter().map(local).collect() };
                let segments = doc
                    .segments
                    .iter()
                    .filter(|s| s.take == index as i64)
                    .map(|s| {
                        let mut z = s.clone();
                        if let (Some(fx), Some(fy)) = (s.focus_x, s.focus_y) {
                            let p = crop.local(fx, fy);
                            z.focus_x = Some(p.0);
                            z.focus_y = Some(p.1);
                        }
                        z
                    })
                    .collect();
                Look {
                    dir: take.dir.clone(),
                    crop,
                    blurs: doc.blurs.iter().filter(|b| b.take == index as i64).cloned().collect(),
                    frame,
                    px_per_point: ppp,
                    cursor_base_height: POINT_HEIGHT * doc.cursor_scale * ppp,
                    has_cursor: !take.cursor.samples.is_empty(),
                    clicks,
                    cursor_track: SmoothTrack::make(&samples, meta.duration, camera_math::cursor_omega(doc.cursor_smoothing)),
                    focus_track: SmoothTrack::make(&samples, meta.duration, camera_math::CAMERA_OMEGA),
                    segments,
                    radius,
                    shadow,
                    meta,
                }
            })
            .collect::<Vec<_>>();

        let base = looks.iter().map(|l| l.cursor_base_height).fold(None, |m: Option<f64>, v| Some(m.map_or(v, |m| m.max(v)))).unwrap_or(40.0);
        let cursor_art_height = (base * 2.5).max(24.0).min(512.0).round() as u32;
        let backdrop = backdrop_plan(doc, cwf, chf);
        Planner { doc: doc.clone(), map, canvas: Size { width: cw as u32, height: ch as u32 }, backdrop, cursor_art_height, looks, captions: vec![] }
    }

    fn look(&self, take: i64) -> Option<&Look> {
        usize::try_from(take).ok().and_then(|i| self.looks.get(i)).or(self.looks.first())
    }

    /// Where take `take` sits on the canvas.
    pub fn frame_rect(&self, take: i64) -> Rect {
        self.look(take).map_or(Rect::new(0.0, 0.0, 0.0, 0.0), |l| l.frame)
    }

    pub fn crop(&self, take: i64) -> NormRect {
        self.look(take).map_or(NormRect::FULL, |l| l.crop)
    }

    /// The camera in take `take` at take time `time` (cropped picture's coordinates).
    pub fn camera(&self, take: i64, time: f64) -> Camera {
        self.look(take).map_or(Camera::IDENTITY, |l| camera_math::camera_at(time, &l.segments, &l.focus_track))
    }

    pub fn camera_at(&self, t: f64) -> Camera {
        let p = self.map.locate(t);
        self.camera(p.take, p.time)
    }

    /// The smoothed pointer of take `take` at take time `time` (cropped picture's coordinates).
    pub fn cursor_position(&self, take: i64, time: f64) -> (f64, f64) {
        self.look(take).map_or((0.5, 0.5), |l| l.cursor_track.position(time))
    }

    pub fn duration(&self) -> f64 {
        self.map.duration()
    }

    /// The whole frame's point (take coordinates, 0...1) under a point of a
    /// view `view_w` x `view_h` showing the canvas aspect-fit, at output time
    /// `t`; None outside the recording. (EditorModel.contentPoint.)
    pub fn content_point(&self, px: f64, py: f64, view_w: f64, view_h: f64, t: f64) -> Option<(f64, f64)> {
        let (cw, ch) = (self.canvas.width as f64, self.canvas.height as f64);
        let k = (view_w / cw).min(view_h / ch);
        let (sw, sh) = (cw * k, ch * k);
        let (ox, oy) = ((view_w - sw) / 2.0, (view_h - sh) / 2.0);
        let (cx, cy) = ((px - ox) / k, (py - oy) / k);
        let here = self.map.locate(t);
        let f = self.frame_rect(here.take);
        let u = (cx - f.x) / f.w;
        let v = (cy - f.y) / f.h;
        if !((0.0..=1.0).contains(&u) && (0.0..=1.0).contains(&v)) {
            return None;
        }
        let (vx, vy, vw, vh) = self.camera(here.take, here.time).viewport();
        Some(self.crop(here.take).global(vx + u * vw, vy + v * vh))
    }

    /// Where the camera looks at output time `t`, in the whole frame's
    /// coordinates. (EditorModel.cameraCentre.)
    pub fn camera_centre(&self, t: f64) -> (f64, f64) {
        let p = self.map.locate(t);
        let c = self.camera(p.take, p.time);
        self.crop(p.take).global(c.center_x, c.center_y)
    }

    /// The frame at output time `t`.
    pub fn plan(&self, t: f64) -> FramePlan {
        let p = self.map.locate(t);
        let mut plan = self.plan_take(p.take, p.time);
        plan.t = t;
        plan.clip_index = p.index;
        plan.webcam = self.webcam(t, p.take, p.time);
        plan.veil = 1.0 - self.map.presence(t);
        plan.speed = self.map.spans.get(p.index).map_or(1.0, |s| s.speed);
        plan.texts = self.texts(t);
        plan
    }

    /// Every text showing at output time `t`.
    pub fn texts(&self, t: f64) -> Vec<TextPlan> {
        let (w, h) = (self.canvas.width as f64, self.canvas.height as f64);
        self.doc
            .overlays()
            .iter()
            .chain(self.captions.iter().filter(|o| o.covers(t)))
            .filter_map(|o| {
                let st = text_motion::state(o, t, w, h)?;
                if st.opacity <= 0.001 {
                    return None;
                }
                let backed = o.has_backing();
                Some(TextPlan {
                    lines: st.lines,
                    px: st.px,
                    tracking: st.tracking,
                    center: Point { x: st.center_x, y: st.center_y },
                    opacity: st.opacity,
                    scale: st.scale,
                    words: st.words,
                    color: Rgba::hex(o.tone.hex(), 1.0),
                    backing: backed.then(|| Rgba::hex(o.tone.backing_hex(), o.tone.backing_alpha())),
                    shadow: text_motion::has_shadow(&o.tone, backed),
                    highlight: st.highlight,
                    highlight_color: st.highlight.map(|_| Rgba::hex(o.tone.highlight_hex(), 1.0)),
                })
            })
            .collect()
    }

    /// The frame from take `take` at its own time `time` (no webcam).
    pub fn plan_take(&self, take: i64, time: f64) -> FramePlan {
        let doc = &self.doc;
        let Some(l) = self.look(take) else {
            return FramePlan {
                t: time,
                canvas: self.canvas,
                clip_index: 0,
                take,
                take_time: time,
                backdrop: self.backdrop.clone(),
                shadow: None,
                frame: Rect::new(0.0, 0.0, 0.0, 0.0),
                corner_radius: 0.0,
                source: SourcePlan {
                    take,
                    width: 0,
                    height: 0,
                    hides: vec![],
                    bounds: Rect::new(0.0, 0.0, 0.0, 0.0),
                    rect: Rect::new(0.0, 0.0, 0.0, 0.0),
                    lanczos: false,
                },
                camera: Camera::IDENTITY,
                ripples: vec![],
                cursor: None,
                webcam: vec![],
                veil: 0.0,
                speed: 1.0,
                texts: vec![],
            };
        };
        let cam = camera_math::camera_at(time, &l.segments, &l.focus_track);
        let (sw, sh) = (l.meta.pixel_width as f64, l.meta.pixel_height as f64);
        let whole = Rect::new(0.0, 0.0, sw, sh);
        let hides = hides(&l.blurs, time, sw, sh);
        let bounds = if l.crop.is_full() {
            whole
        } else {
            let r = Rect::new(l.crop.x * sw, l.crop.y * sh, l.crop.w * sw, l.crop.h * sh).integral().intersection(&whole);
            if r.w >= 2.0 && r.h >= 2.0 { r } else { whole }
        };
        let (vx, vy, vw, vh) = cam.viewport();
        let view = Rect::new(bounds.x + vx * bounds.w, bounds.y + vy * bounds.h, vw * bounds.w, vh * bounds.h);
        // CoreImage scales by one factor (from the widths) and pins the
        // view's bottom edge to the frame's (its origin is bottom-left); the
        // frame's whole-pixel height can differ a hair from the view's shape.
        let k = l.frame.w / view.w;
        let rect = Rect::new(view.x, view.max_y() - l.frame.h / k, view.w, l.frame.h / k);
        let frame = l.frame;

        let mut ripples = vec![];
        let mut cursor = None;
        if doc.cursor_visible && l.has_cursor {
            let zoom = cam.scale;
            let place = |x: f64, y: f64| {
                let p = cam.project(x, y);
                Point { x: frame.x + p.0 * frame.w, y: frame.y + p.1 * frame.h }
            };
            let style = doc.cursor_style.known();
            if doc.click_ripple {
                let tint = if style.tinted() { doc.cursor_tint.hex() } else { 0xA6BBC3 };
                for (c, progress) in camera_math::ripples(&l.clicks, time, camera_math::RIPPLE_DURATION) {
                    let grow = 1.0 - (1.0 - progress).powi(3);
                    ripples.push(RipplePlan {
                        center: place(c.x, c.y),
                        radius: (9.0 + 24.0 * grow) * l.px_per_point * zoom * doc.cursor_scale / 1.5,
                        alpha: 0.85 * (1.0 - progress),
                        color: Rgba::hex(tint, 1.0),
                    });
                }
            }
            let pos = l.cursor_track.position(time);
            cursor = Some(CursorPlan {
                style: style.as_str().to_string(),
                tint: doc.cursor_tint.known().as_str().to_string(),
                label: doc.cursor_label.clone(),
                art_height: self.cursor_art_height,
                tip: place(pos.0, pos.1),
                height: l.cursor_base_height * zoom * camera_math::press_scale(&l.clicks, time),
            });
        }

        FramePlan {
            t: time,
            canvas: self.canvas,
            clip_index: 0,
            take,
            take_time: time,
            backdrop: self.backdrop.clone(),
            shadow: l.shadow.clone(),
            frame,
            corner_radius: if l.radius > 0.5 { l.radius } else { 0.0 },
            source: SourcePlan {
                take,
                width: l.meta.pixel_width,
                height: l.meta.pixel_height,
                hides,
                bounds,
                rect,
                lanczos: k < 0.75,
            },
            camera: cam,
            ripples,
            cursor,
            webcam: vec![],
            veil: 0.0,
            speed: 1.0,
            texts: vec![],
        }
    }

    /// Where the camera bubble sits on the canvas (before it grows in).
    pub fn bubble_rect(&self) -> Rect {
        let look = &self.doc.camera_look;
        let (cw, ch) = (self.canvas.width as f64, self.canvas.height as f64);
        let short = cw.min(ch);
        let h = (look.size * short).round();
        let w = if look.shape.known() == CameraShape::Circle { h } else { (h * 4.0 / 3.0).round() };
        let m = (0.045 * short).round();
        let corner = look.corner.known();
        let right = matches!(corner, CameraCorner::BottomRight | CameraCorner::TopRight);
        let bottom = matches!(corner, CameraCorner::BottomRight | CameraCorner::BottomLeft);
        Rect::new(if right { cw - m - w } else { m }, if bottom { ch - m - h } else { m }, w, h)
    }

    fn webcam(&self, t: f64, take: i64, take_time: f64) -> Vec<WebcamPlan> {
        let doc = &self.doc;
        if !doc.camera_look.visible {
            return vec![];
        }
        let mut out = vec![];
        let mut clips = doc.camera_clips.clone();
        clips.sort_by(|a, b| a.at.total_cmp(&b.at));
        if let Some(c) = clips.iter().find(|c| c.covers(t)) {
            out.push(self.webcam_plan(WebcamKind::Overlay, c.file.clone(), t - c.at, c.full, camera::presence(c, t), take));
        }
        if let Some(l) = self.look(take) {
            if let Some(file) = &l.meta.camera {
                let time = take_time - l.meta.camera_offset;
                if time >= 0.0 {
                    let path = if l.dir.is_empty() { file.clone() } else { format!("{}/{}", l.dir, file) };
                    out.push(self.webcam_plan(WebcamKind::Take, path, time, false, 1.0, take));
                }
            }
        }
        out
    }

    fn webcam_plan(&self, kind: WebcamKind, file: String, time: f64, full: bool, presence: f64, take: i64) -> WebcamPlan {
        let mirror = self.doc.camera_look.mirror;
        if full {
            let rect = self.frame_rect(take);
            let radius = if self.doc.backdrop.known() != Backdrop::None { self.doc.corner_radius * rect.w.min(rect.h) } else { 0.0 };
            return WebcamPlan {
                kind,
                file,
                time,
                full,
                opacity: presence,
                mirror,
                rect,
                radius: if radius > 0.5 { radius } else { 0.0 },
                rim: None,
                shadow: None,
            };
        }
        // The bubble grows in a little as it fades in.
        let base = self.bubble_rect();
        let grow = 0.86 + 0.14 * presence;
        let (mx, my) = (base.x + base.w / 2.0, base.y + base.h / 2.0);
        let rect = Rect::new(mx - base.w * grow / 2.0, my - base.h * grow / 2.0, base.w * grow, base.h * grow);
        let radius = if self.doc.camera_look.shape.known() == CameraShape::Circle { rect.h / 2.0 } else { rect.h * 0.2 };
        let rim = 2f64.max(rect.h * 0.018);
        WebcamPlan {
            kind,
            file,
            time,
            full,
            opacity: presence,
            mirror,
            rect,
            radius,
            rim: Some(RimPlan { rect: rect.inset(-rim), radius: radius + rim, color: Rgba::new(1.0, 1.0, 1.0, 0.96) }),
            shadow: Some(ShadowPlan {
                rect: Rect::new(rect.x, rect.y + rect.h * 0.03, rect.w, rect.h),
                radius,
                color: Rgba::new(0.04, 0.03, 0.02, 0.38),
                sigma: rect.h * 0.045,
            }),
        }
    }
}

/// The hidden boxes showing at take time `time`, in source pixels.
pub fn hides(blurs: &[BlurRegion], time: f64, w: f64, h: f64) -> Vec<HidePlan> {
    let whole = Rect::new(0.0, 0.0, w, h);
    let short = w.min(h);
    blurs
        .iter()
        .filter(|b| b.covers(time))
        .filter_map(|b| {
            let r = Rect::new(b.rect.x * w, b.rect.y * h, b.rect.w * w, b.rect.h * h).integral().intersection(&whole);
            if r.w < 1.0 || r.h < 1.0 {
                return None;
            }
            let k = b.strength.max(0.0).min(1.0);
            let (style, sigma, cell) = match b.style.known() {
                BlurStyle::Pixelate => (HideStyle::Pixelate, 0.0, 4f64.max((0.008 + 0.035 * k) * short)),
                BlurStyle::Solid => (HideStyle::Solid, 0.0, 0.0),
                _ => (HideStyle::Blur, (0.006 + 0.03 * k) * short, 0.0),
            };
            Some(HidePlan { style, rect: r, sigma, cell, color: Rgba::new(0.09, 0.10, 0.11, 1.0) })
        })
        .collect()
}

/// The canvas behind the recording.
pub fn backdrop_plan(doc: &EditDoc, w: f64, h: f64) -> BackdropPlan {
    let charcoal = || BackdropPlan::Linear {
        from: Point { x: 0.0, y: h },
        to: Point { x: w * 0.3, y: 0.0 },
        color_from: Rgba::hex(0x17191B, 1.0),
        color_to: Rgba::hex(0x303336, 1.0),
        grain: 0.03,
    };
    match doc.backdrop.known() {
        Backdrop::Paper => BackdropPlan::Solid { color: Rgba::hex(0xF3F0E8, 1.0), grain: 0.045 },
        Backdrop::Charcoal => charcoal(),
        Backdrop::Dusk => BackdropPlan::Linear {
            from: Point { x: w, y: h },
            to: Point { x: 0.0, y: 0.0 },
            color_from: Rgba::hex(0x2B211C, 1.0),
            color_to: Rgba::hex(0xB8694A, 1.0),
            grain: 0.03,
        },
        Backdrop::Slate => BackdropPlan::Linear {
            from: Point { x: w * 0.8, y: h },
            to: Point { x: w * 0.1, y: 0.0 },
            color_from: Rgba::hex(0x252C30, 1.0),
            color_to: Rgba::hex(0x6E8088, 1.0),
            grain: 0.03,
        },
        Backdrop::None => BackdropPlan::Solid { color: Rgba::hex(0x000000, 1.0), grain: 0.0 },
        _ => match &doc.backdrop_image {
            Some(file) => BackdropPlan::Image {
                file: file.clone(),
                blur_sigma: if doc.backdrop_blur > 0.01 { doc.backdrop_blur * 0.03 * w.min(h) } else { 0.0 },
                fallback: Box::new(charcoal()),
            },
            None => charcoal(),
        },
    }
}

/// The ring's alpha at distance `d` from a ripple's centre, as a fraction of
/// its peak alpha: 0 inside 0.55 r, rising to 1 at 0.78 r, falling to 0 at r.
pub fn ripple_profile(d: f64, radius: f64) -> f64 {
    let (a, b) = (0.55 * radius, 0.78 * radius);
    if d <= a || d >= radius {
        return 0.0;
    }
    let outer = if d <= b { 1.0 } else { (radius - d) / (radius - b) };
    let inner = if d <= b { (b - d) / (b - a) } else { 0.0 };
    outer * (1.0 - inner)
}
