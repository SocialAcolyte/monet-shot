//! monetshot-core for the editor's webview. The preview asks `Editor.plan(t)`
//! for the same FramePlan the export draws; the timeline and inspector use
//! the pure edits here instead of re-porting Kit logic in TypeScript.
//!
//! Values cross as plain JS objects shaped like the .reel JSON (camelCase
//! keys) and the FramePlan contract (`docs/porting/contracts/frame-plan.md`).
//! Inputs may also be JSON strings. Bad input throws an Error. Take and clip
//! indices are plain numbers (i32 here, i64 inside).

use monetshot_core::camera as camera_mod;
use monetshot_core::camera_math::{self, segment_edits};
use monetshot_core::json::to_swift_json;
use monetshot_core::music::MusicGrid;
use monetshot_core::plan::{self, PlanTake, Planner};
use monetshot_core::timemap::clip_edits;
use monetshot_core::*;
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use wasm_bindgen::prelude::*;

type R<T> = Result<T, JsError>;

/// JS value (object or JSON string) -> T, through JSON so numbers, ids and
/// unknown keys behave exactly as when reading the files.
fn from_js<T: DeserializeOwned>(v: &JsValue) -> R<T> {
    let text = match v.as_string() {
        Some(s) => s,
        None => js_sys::JSON::stringify(v)
            .map_err(|_| JsError::new("value is not JSON"))?
            .as_string()
            .unwrap_or_default(),
    };
    serde_json::from_str(&text).map_err(|e| JsError::new(&e.to_string()))
}

fn to_js<T: Serialize + ?Sized>(v: &T) -> R<JsValue> {
    v.serialize(&serde_wasm_bindgen::Serializer::json_compatible()).map_err(|e| JsError::new(&e.to_string()))
}

#[derive(Deserialize)]
struct TakeIn {
    meta: RecordingMeta,
    #[serde(default)]
    cursor: CursorTrack,
    #[serde(default)]
    dir: String,
}

#[derive(Serialize)]
struct XY {
    x: f64,
    y: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Viewport {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    scale: f64,
    center_x: f64,
    center_y: f64,
}

/// One open recording: its takes and the current edit.
#[wasm_bindgen]
pub struct Editor {
    takes: Vec<PlanTake>,
    planner: Planner,
}

#[wasm_bindgen]
impl Editor {
    /// `edit`: edit.json; `takes`: [{meta, cursor, dir}] in take order
    /// (meta.json, cursor.json, folder relative to the .reel: "" for the first).
    #[wasm_bindgen(constructor)]
    pub fn new(edit: JsValue, takes: JsValue) -> R<Editor> {
        let doc: EditDoc = from_js(&edit)?;
        let takes: Vec<TakeIn> = from_js(&takes)?;
        let takes: Vec<PlanTake> = takes.into_iter().map(|t| PlanTake { meta: t.meta, cursor: t.cursor, dir: t.dir }).collect();
        let planner = Planner::new(&doc, &takes);
        Ok(Editor { takes, planner })
    }

    /// After any edit: re-plans (smooths every pointer again; a few ms).
    #[wasm_bindgen(js_name = setEdit)]
    pub fn set_edit(&mut self, edit: JsValue) -> R<()> {
        let doc: EditDoc = from_js(&edit)?;
        self.planner = Planner::new(&doc, &self.takes);
        Ok(())
    }

    /// The edit as the planner read it (defaults filled in).
    pub fn edit(&self) -> R<JsValue> {
        to_js(&self.planner.doc)
    }

    /// edit.json text exactly as the Mac writes it.
    #[wasm_bindgen(js_name = editJson)]
    pub fn edit_json(&self) -> R<String> {
        to_swift_json(&self.planner.doc).map_err(|e| JsError::new(&e.to_string()))
    }

    /// Output duration, seconds.
    pub fn duration(&self) -> f64 {
        self.planner.duration()
    }

    /// The FramePlan at output time `t`.
    pub fn plan(&self, t: f64) -> R<JsValue> {
        to_js(&self.planner.plan(t))
    }

    /// The FramePlan for take `take` at its own time (no webcam): filmstrips, framing.
    #[wasm_bindgen(js_name = planTake)]
    pub fn plan_take(&self, take: i32, time: f64) -> R<JsValue> {
        to_js(&self.planner.plan_take(take.into(), time))
    }

    #[wasm_bindgen(js_name = canvasSize)]
    pub fn canvas_size(&self) -> R<JsValue> {
        to_js(&self.planner.canvas)
    }

    /// The backdrop plan (the same in every frame).
    pub fn backdrop(&self) -> R<JsValue> {
        to_js(&self.planner.backdrop)
    }

    #[wasm_bindgen(js_name = cursorArtHeight)]
    pub fn cursor_art_height(&self) -> u32 {
        self.planner.cursor_art_height
    }

    /// The clips in play order.
    pub fn clips(&self) -> R<JsValue> {
        to_js(&self.planner.doc.kept_clips(self.takes.first().map_or(0.0, |t| t.meta.duration)))
    }

    /// Where each clip starts in output time.
    pub fn starts(&self) -> R<JsValue> {
        let clips = self.planner.doc.kept_clips(self.takes.first().map_or(0.0, |t| t.meta.duration));
        to_js(&clip_edits::starts(&clips))
    }

    /// [{take, start, end, at}]
    pub fn spans(&self) -> R<JsValue> {
        to_js(&self.planner.map.spans)
    }

    /// {index, take, time}
    pub fn locate(&self, t: f64) -> R<JsValue> {
        to_js(&self.planner.map.locate(t))
    }

    /// Output time of a take moment, as it first appears; undefined if no clip shows it.
    pub fn output(&self, take: i32, time: f64) -> Option<f64> {
        self.planner.map.output(take.into(), time)
    }

    pub fn keeps(&self, take: i32, time: f64) -> bool {
        self.planner.map.keeps(take.into(), time)
    }

    /// Where take `take` sits on the canvas (px, top-left).
    #[wasm_bindgen(js_name = frameRect)]
    pub fn frame_rect(&self, take: i32) -> R<JsValue> {
        to_js(&self.planner.frame_rect(take.into()))
    }

    /// The camera's view of take `take` at take time `time`, in the cropped
    /// picture's 0...1 coordinates: {x, y, w, h, scale, centerX, centerY}.
    pub fn viewport(&self, take: i32, time: f64) -> R<JsValue> {
        let c = self.planner.camera(take.into(), time);
        let (x, y, w, h) = c.viewport();
        to_js(&Viewport { x, y, w, h, scale: c.scale, center_x: c.center_x, center_y: c.center_y })
    }

    /// Take `take`'s crop ({x,y,w,h}, the whole frame when none).
    pub fn crop(&self, take: i32) -> R<JsValue> {
        to_js(&self.planner.crop(take.into()))
    }

    /// A point in take `take`'s crop coordinates, in the whole frame's.
    #[wasm_bindgen(js_name = cropGlobal)]
    pub fn crop_global(&self, take: i32, x: f64, y: f64) -> R<JsValue> {
        let p = self.planner.crop(take.into()).global(x, y);
        to_js(&XY { x: p.0, y: p.1 })
    }

    /// The smoothed pointer (cropped picture's coordinates).
    #[wasm_bindgen(js_name = cursorPosition)]
    pub fn cursor_position(&self, take: i32, time: f64) -> R<JsValue> {
        let p = self.planner.cursor_position(take.into(), time);
        to_js(&XY { x: p.0, y: p.1 })
    }

    /// EditorModel.contentPoint: the take's 0...1 point under (px, py) of a
    /// view `w` x `h` that shows the canvas aspect-fit, at output time `t`;
    /// null outside the recording.
    #[wasm_bindgen(js_name = contentPoint)]
    pub fn content_point(&self, px: f64, py: f64, w: f64, h: f64, t: f64) -> R<JsValue> {
        match self.planner.content_point(px, py, w, h, t) {
            Some(p) => to_js(&XY { x: p.0, y: p.1 }),
            None => Ok(JsValue::NULL),
        }
    }

    /// EditorModel.cameraCentre: where the camera looks at `t`, whole frame's coordinates.
    #[wasm_bindgen(js_name = cameraCentre)]
    pub fn camera_centre(&self, t: f64) -> R<JsValue> {
        let p = self.planner.camera_centre(t);
        to_js(&XY { x: p.0, y: p.1 })
    }

    /// Where the camera bubble sits (px, top-left), before it grows in.
    #[wasm_bindgen(js_name = bubbleRect)]
    pub fn bubble_rect(&self) -> R<JsValue> {
        to_js(&self.planner.bubble_rect())
    }
}

// MARK: pure edits (ClipEdits)

#[wasm_bindgen(js_name = clipStarts)]
pub fn clip_starts(clips: JsValue) -> R<JsValue> {
    to_js(&clip_edits::starts(&from_js::<Vec<Clip>>(&clips)?))
}

/// ClipEdits.split(clips, atOutput:): null if too near an edge.
#[wasm_bindgen(js_name = clipSplit)]
pub fn clip_split(clips: JsValue, at_output: f64) -> R<JsValue> {
    match clip_edits::split(&from_js::<Vec<Clip>>(&clips)?, at_output) {
        Some(c) => to_js(&c),
        None => Ok(JsValue::NULL),
    }
}

#[wasm_bindgen(js_name = clipDelete)]
pub fn clip_delete(clips: JsValue, i: i32) -> R<JsValue> {
    to_js(&clip_edits::delete(&from_js::<Vec<Clip>>(&clips)?, i.into()))
}

#[wasm_bindgen(js_name = clipResize)]
pub fn clip_resize(clips: JsValue, i: i32, leading: bool, to: f64, take_duration: f64) -> R<JsValue> {
    to_js(&clip_edits::resize(&from_js::<Vec<Clip>>(&clips)?, i.into(), leading, to, take_duration))
}

#[wasm_bindgen(js_name = clipMove)]
pub fn clip_move(clips: JsValue, from: i32, to: i32) -> R<JsValue> {
    to_js(&clip_edits::move_clip(&from_js::<Vec<Clip>>(&clips)?, from.into(), to.into()))
}

#[wasm_bindgen(js_name = clipDropIndex)]
pub fn clip_drop_index(clips: JsValue, dragging: i32, centre_at: f64) -> R<i32> {
    Ok(clip_edits::drop_index(&from_js::<Vec<Clip>>(&clips)?, dragging.into(), centre_at) as i32)
}

/// EditDoc.keptClips(duration:)
#[wasm_bindgen(js_name = keptClips)]
pub fn kept_clips(edit: JsValue, duration: f64) -> R<JsValue> {
    to_js(&from_js::<EditDoc>(&edit)?.kept_clips(duration))
}

// MARK: zooms (CameraMath, SegmentEdits)

/// CameraMath.autoZooms(clicks:duration:scale:take:) (scale defaults to 2).
#[wasm_bindgen(js_name = autoZooms)]
pub fn auto_zooms(clicks: JsValue, duration: f64, take: i32, scale: Option<f64>) -> R<JsValue> {
    let clicks: Vec<CursorSample> = from_js(&clicks)?;
    to_js(&camera_math::auto_zooms_with(&clicks, duration, scale.unwrap_or(camera_math::DEFAULT_SCALE), take.into()))
}

/// SegmentEdits.insert: a new hand-made zoom (with a fresh id), or null.
#[wasm_bindgen(js_name = segmentInsert)]
pub fn segment_insert(at: f64, segments: JsValue, duration: f64, take: i32, length: Option<f64>) -> R<JsValue> {
    let segments: Vec<ZoomSegment> = from_js(&segments)?;
    match segment_edits::insert(at, &segments, duration, length.unwrap_or(2.5), take.into()) {
        Some(s) => to_js(&s),
        None => Ok(JsValue::NULL),
    }
}

#[wasm_bindgen(js_name = segmentMove)]
pub fn segment_move(segment: JsValue, delta: f64, duration: f64) -> R<JsValue> {
    to_js(&segment_edits::move_by(&from_js(&segment)?, delta, duration))
}

#[wasm_bindgen(js_name = segmentResize)]
pub fn segment_resize(segment: JsValue, leading: bool, to: f64, duration: f64) -> R<JsValue> {
    to_js(&segment_edits::resize(&from_js(&segment)?, leading, to, duration))
}

#[wasm_bindgen(js_name = segmentReAuto)]
pub fn segment_re_auto(segments: JsValue, clicks: JsValue, duration: f64, take: i32) -> R<JsValue> {
    let segments: Vec<ZoomSegment> = from_js(&segments)?;
    let clicks: Vec<CursorSample> = from_js(&clicks)?;
    to_js(&segment_edits::re_auto(&segments, &clicks, duration, take.into()))
}

// MARK: camera, crop, music

/// CameraEdits.insert(clip, into:)
#[wasm_bindgen(js_name = cameraInsert)]
pub fn camera_insert(clip: JsValue, clips: JsValue) -> R<JsValue> {
    let clip: CameraClip = from_js(&clip)?;
    let clips: Vec<CameraClip> = from_js(&clips)?;
    to_js(&camera_mod::insert(clip, &clips))
}

#[wasm_bindgen(js_name = cameraPresence)]
pub fn camera_presence(clip: JsValue, t: f64) -> R<f64> {
    Ok(camera_mod::presence(&from_js(&clip)?, t))
}

#[wasm_bindgen(js_name = normRectClamped)]
pub fn norm_rect_clamped(rect: JsValue, min_size: Option<f64>) -> R<JsValue> {
    to_js(&from_js::<NormRect>(&rect)?.clamped(min_size.unwrap_or(0.02)))
}

#[wasm_bindgen(js_name = normRectMoved)]
pub fn norm_rect_moved(rect: JsValue, dx: f64, dy: f64) -> R<JsValue> {
    to_js(&from_js::<NormRect>(&rect)?.moved(dx, dy))
}

/// NormRect.resized(handleX:handleY:dx:dy:minSize:)
#[wasm_bindgen(js_name = normRectResized)]
pub fn norm_rect_resized(rect: JsValue, hx: f64, hy: f64, dx: f64, dy: f64, min_size: Option<f64>) -> R<JsValue> {
    to_js(&from_js::<NormRect>(&rect)?.resized(hx, hy, dx, dy, min_size.unwrap_or(0.02)))
}

#[wasm_bindgen(js_name = normRectSpanning)]
pub fn norm_rect_spanning(ax: f64, ay: f64, bx: f64, by: f64) -> R<JsValue> {
    to_js(&NormRect::spanning((ax, ay), (bx, by)))
}

/// EditDoc.setCrop(rect, take:): returns the new edit.
#[wasm_bindgen(js_name = setCrop)]
pub fn set_crop(edit: JsValue, rect: JsValue, take: i32) -> R<JsValue> {
    let mut doc: EditDoc = from_js(&edit)?;
    doc.set_crop(from_js(&rect)?, take.into());
    to_js(&doc)
}

/// EditDoc.canvasSize(recordingAspect:) -> {width, height}
#[wasm_bindgen(js_name = canvasSize)]
pub fn canvas_size(edit: JsValue, recording_aspect: f64) -> R<JsValue> {
    let (width, height) = from_js::<EditDoc>(&edit)?.canvas_size(recording_aspect);
    to_js(&serde_json::json!({ "width": width, "height": height }))
}

/// MusicGrid.nearestBarLine: `grid` is {bar, firstDownbeat, lifts}.
#[wasm_bindgen(js_name = nearestBarLine)]
pub fn nearest_bar_line(grid: JsValue, t: f64) -> R<f64> {
    Ok(from_js::<MusicGrid>(&grid)?.nearest_bar_line(t))
}

/// MusicEnvelope.gain: `voice` is [[start, end], …] in output time.
#[wasm_bindgen(js_name = musicGain)]
pub fn music_gain(t: f64, length: f64, fade_in: bool, fade_out: bool, voice: JsValue) -> R<f64> {
    let voice: Vec<(f64, f64)> = from_js(&voice)?;
    Ok(music_envelope::gain(t, length, fade_in, fade_out, &voice))
}

/// The ripple ring's alpha profile (0...1) at distance `d`, radius `r`.
#[wasm_bindgen(js_name = rippleProfile)]
pub fn ripple_profile(d: f64, r: f64) -> f64 {
    plan::ripple_profile(d, r)
}

/// A fresh id as the Mac writes them.
#[wasm_bindgen(js_name = newId)]
pub fn new_id_js() -> String {
    new_id()
}

/// Any .reel value as the Mac would write it (edit/meta/cursor objects).
#[wasm_bindgen(js_name = swiftJson)]
pub fn swift_json(value: JsValue) -> R<String> {
    let v: serde_json::Value = from_js(&value)?;
    to_swift_json(&v).map_err(|e| JsError::new(&e.to_string()))
}

// MARK: cursor art

/// A rendered cursor sprite: `rgba` is premultiplied sRGB RGBA8, `width` x
/// `height`; the hotspot is (`tipX`, `tipY`) px from the top-left.
#[wasm_bindgen(getter_with_clone)]
pub struct CursorSprite {
    pub width: u32,
    pub height: u32,
    #[wasm_bindgen(js_name = tipX)]
    pub tip_x: f64,
    #[wasm_bindgen(js_name = tipY)]
    pub tip_y: f64,
    pub rgba: Vec<u8>,
}

/// The cursor as the export draws it, `pixelHeight` tall (use the plan's
/// `cursor.artHeight`). Render once per look and cache it.
#[wasm_bindgen(js_name = cursorArt)]
pub fn cursor_art(style: &str, tint: &str, label: &str, pixel_height: u32) -> CursorSprite {
    let a = monetshot_export::cursor_art(&CursorStyle::parse(style), &CursorTint::parse(tint), label, pixel_height);
    CursorSprite { width: a.width, height: a.height, tip_x: a.tip_x, tip_y: a.tip_y, rgba: a.rgba }
}
