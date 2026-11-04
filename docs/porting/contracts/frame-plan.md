# FramePlan contract

Owner: **ms-core**. Readers: ms-app (WebGL2 preview painter), the export
crate (tiny-skia painter). Code is the truth: `desktop/crates/core/src/plan.rs`
(a port of `Sources/MonetShotKit/Render/Renderer.swift`).

One brain, two painters: `Planner::plan(t)` decides everything about the
frame at output time `t`; a painter only draws what the plan says, in the
order below. Same plan, same picture.

## Coordinates and colour

- **Canvas pixels, origin top-left, y down.** (CoreImage's bottom-left
  origin is already flipped.) Source rects are in the take's raw video
  pixels, also top-left.
- Colours are `{r,g,b,a}` 0..1, **sRGB-encoded, straight alpha**.
- CoreImage works in **linear light**: gradients, blurs, shadows, the
  Lanczos shrink and alpha compositing all happen on linear values. Do the
  same (decode sRGB → work → encode) or blurs/shadows/gradient midpoints
  come out darker than the Mac's.
- **Except plain bilinear sampling of an 8-bit picture**: when CoreImage
  just transforms an image (the source when *not* `lanczos`, the webcam,
  the painting backdrop), it interpolates the stored gamma values and only
  then converts to linear. So in WebGL2 sample those from a plain `RGBA8`
  texture (not `SRGB8_ALPHA8`) with `LINEAR` filtering and decode the
  result in the shader; use an sRGB texture (linear filtering, mipmaps) for
  the `lanczos` shrink. Measured against the Mac's frames this is the
  difference between 2.2/255 and 0.14/255 mean error on a zoomed frame.
- The painting backdrop is a bilinear cover-fit with no prefilter (it
  aliases a little before the blur, as on the Mac).

## Getting a plan (core-wasm)

```ts
import init, { Editor, cursorArt } from "monetshot-core-wasm";
await init();
// takes: meta.json + cursor.json per take, in take order; dir relative to the .reel
const ed = new Editor(editJson, [{ meta, cursor, dir: "" }, { meta, cursor, dir: "take-2" }]);
ed.duration();               // output seconds
const plan: FramePlan = ed.plan(t);   // plain JS object, shape below
ed.setEdit(editJson);        // after any edit: re-plans (smooths pointers again)
```

Build: `desktop/crates/core-wasm/build.sh` (-> `desktop/crates/core-wasm/pkg/`).
The full API is in `pkg/monetshot_core_wasm.d.ts`. `cargo run -p
monetshot-core --example plan_dump -- <reel> <t>...` prints real plans.

How close the export painter gets to the Mac (`cargo test -p
monetshot-export --test render`, against `shared/fixtures/render/`): mean
0.04–0.8/255 per frame; what's left is grain noise and one-pixel seams.

## Shape (TypeScript)

```ts
type Rect = { x: number; y: number; w: number; h: number };
type Point = { x: number; y: number };
type Rgba = { r: number; g: number; b: number; a: number };

interface FramePlan {
  t: number;                 // output time
  canvas: { width: number; height: number };   // even height
  clipIndex: number;         // which clip plays
  take: number;              // its take
  takeTime: number;          // seek the take's video here
  backdrop: BackdropPlan;    // same for every t of an edit: cache it
  shadow: ShadowPlan | null; // under the frame
  frame: Rect;               // where the recording sits (whole pixels)
  cornerRadius: number;      // 0 = square corners
  source: SourcePlan;
  camera: { scale: number; centerX: number; centerY: number }; // info (zoom lane); already applied in source.rect
  ripples: RipplePlan[];     // under the cursor
  cursor: CursorPlan | null;
  webcam: WebcamPlan[];      // candidates, priority order
  veil: number;              // a clip fading: the backdrop again over everything at this opacity (0 = none)
  speed: number;             // the clip's speed: play the take's video (and its own camera) at this rate
  texts: TextPlan[];         // words, drawn last (over the veil), in order
}

interface TextPlan {
  lines: string[]; px: number; tracking: number;   // what textArt(plan) draws
  center: Point; scale: number; opacity: number;   // where and how: centred, scaled about its centre
  words: number[];             // per-word alpha (word by word); [] = all shown
  color: Rgba; backing: Rgba | null; shadow: boolean;
}
// textArt(plan) (core-wasm, the export crate's text_art) gives the picture,
// premultiplied sRGB, the same bytes the export draws; cache on everything
// but center/scale/opacity. Inter Bold from Resources/Fonts, laid out with
// text_motion's fixed em metrics, so it matches CoreText to 0.05 px.

type BackdropPlan =
  | { kind: "solid"; color: Rgba; grain: number }
  | { kind: "linear"; from: Point; to: Point; colorFrom: Rgba; colorTo: Rgba; grain: number }
  | { kind: "image"; file: string; blurSigma: number; fallback: BackdropPlan };

interface ShadowPlan { rect: Rect; radius: number; color: Rgba; sigma: number }

interface SourcePlan {
  take: number;
  width: number; height: number;   // raw frame size (meta.json)
  hides: HidePlan[];               // drawn into the raw frame first
  bounds: Rect;                    // the take's crop, whole source px; sampling clamps to it
  rect: Rect;                      // source px shown in `frame` (crop + zoom applied; map it straight onto frame, same scale both axes)
  lanczos: boolean;                // shrinking below 0.75x: use a proper downscale (mipmaps)
}

interface HidePlan {
  style: "blur" | "pixelate" | "solid";
  rect: Rect;      // whole source px, inside the frame
  sigma: number;   // blur: pass 1 sigma; pass 2 = sigma/2 over pass 1
  cell: number;    // pixelate: cell size px, grid starts at rect's top-left
  color: Rgba;     // solid: the cover colour
}

interface CursorPlan {
  style: "classic" | "white" | "soft" | "dot" | "tag";
  tint: "clay" | "sky" | "mint" | "butter" | "lilac" | "rose";
  label: string;       // tag text ("" draws "You")
  artHeight: number;   // render the sprite once at this height: cursorArt(style, tint, label, artHeight)
  tip: Point;          // hotspot on the canvas
  height: number;      // draw the sprite scaled by height/artHeight, hotspot on tip
}

interface RipplePlan { center: Point; radius: number; alpha: number; color: Rgba }

interface WebcamPlan {
  kind: "overlay" | "take";
  file: string;        // relative to the .reel folder
  time: number;        // seconds into that file
  full: boolean;
  opacity: number;     // group opacity; draw nothing when <= 0.001
  mirror: boolean;     // flip the camera picture left-right
  rect: Rect;          // cover-fit the camera picture here
  radius: number;      // clip it to this rounded rect (0 = square)
  rim: { rect: Rect; radius: number; color: Rgba } | null;
  shadow: ShadowPlan | null;
}
```

## Drawing order

1. **Backdrop** (cache per edit).
   - `solid`: fill. `linear`: colour `colorFrom` at `from`, `colorTo` at
     `to`, projected onto the from→to line, clamped beyond both ends,
     interpolated in linear light.
   - `image`: decode `<reel>/<file>`; scale `k = max(W/iw, H/ih)`, centred
     (cover); if `blurSigma > 0` gaussian-blur with edges extended (clamp).
     If the file can't be read, draw `fallback`.
   - `grain > 0`: a still per-pixel noise `n ∈ [0,1)` (the same every
     frame), one value for all three channels: `rgb *= (1 - grain) + grain*n`.
     Not bit-exact with the Mac (CIRandomGenerator); any fixed noise is fine.
2. **Shadow** (cache per take): a rounded rect `rect`/`radius` filled with
   `color`, gaussian-blurred by `sigma`, clipped to the canvas.
3. **Content**, clipped to `frame` and then to the rounded rect
   (`frame`, `cornerRadius`) — the clip applies to 3a–3c together:
   a. The source frame with `source.hides` drawn into it (see Hides), then
      the region `source.rect` stretched onto `frame`. Samples outside
      `source.bounds` take the nearest edge pixel of `bounds` (clamp), never
      transparent black. Bilinear when magnifying; when `lanczos`, filter
      the downscale (mipmaps / multi-tap) so text doesn't shimmer.
   b. **Ripples**, each a ring: alpha at distance `d` from `center` is
      `alpha * profile(d)`, `profile` = 0 for `d ≤ 0.55r`, rising linearly
      to 1 at `0.78r`, falling linearly to 0 at `r`
      (`plan::ripple_profile`). Colour `color`.
   c. **Cursor**: the sprite from `cursorArt(style, tint, label, artHeight)`
      (RGBA premultiplied, its `tip` from the sprite's top-left) drawn
      scaled by `s = height/artHeight` with its tip at `tip`, i.e. top-left
      at `tip - tipInSprite*s`. Use a good minifying filter (the Mac uses Lanczos).
4. **Webcam**: take the first candidate whose file has a frame at `time`
   (overlay files can be shorter than their clip; take cameras can start
   late). If its `opacity ≤ 0.001` draw nothing (don't fall back). Draw as a
   group with that opacity: `shadow` (blurred rounded rect) under `rim`
   (rounded rect fill) under the face (camera picture cover-fitted into
   `rect`, mirrored if `mirror`, clipped to `rect`/`radius`). Full-frame
   candidates have no rim or shadow.
5. **Veil**: if `veil > 0.001`, the backdrop (same picture as step 1)
   again over everything at opacity `veil`, in linear light. This is a
   clip fading in or out (`TimeMap.presence`).
6. **Texts**, in order: `textArt(text)` centred on `center`, scaled by
   `scale` about its centre (bilinear), at `opacity`, decoded to linear
   light and composited over. They sit on top of the veil, so a title can
   stand on the backdrop while the footage fades up.

### Hides (in raw source pixels, before anything else)

- `blur`: take the pixels inside `rect` only (edges extended outward, so
  nothing sharp from outside bleeds in), gaussian `sigma`, then gaussian
  `sigma/2` over that (edges extended again), cut back to `rect`.
- `pixelate`: cells of `cell` px aligned to `rect`'s top-left; each cell
  takes the colour sampled at its centre (clamped to `rect`).
- `solid`: fill `rect` with `color`.

In the preview it is fine to draw hides on the framed output instead of the
raw frame as long as the result looks the same (map `rect` through
`source.rect → frame`).

## What is not in the plan

- Audio (take audio, camera voice, music with fades/ducking): the export
  crate, `music_envelope::gain`.
- Which file a take's video is: `meta.video` in `<reel>/<dir>/`.
- Cursor art pixels: `cursorArt` (core-wasm) / `monetshot_export::cursor_art`.
