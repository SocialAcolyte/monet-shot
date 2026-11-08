# ms-vertical status: videos for phones

Branch `feat/vertical`. Last green CI: see the end of this file.

## What was built (Mac and desktop, same edit.json, same pixels)

**Model.** `layout` in edit.json: `"vertical"` (1080x1920) or `"square"`
(1080x1080). When it's absent the edit is landscape, as before. Landscape's
own keys (`outputWidth`, `canvasAspect`) are never touched, so switching back
gives the old edit byte for byte. Only a non-landscape layout is written. An
unknown value draws as landscape: the desktop keeps it, the Mac drops it.
- Swift: `Sources/MonetShotKit/Core/Vertical.swift`
- Rust: `desktop/crates/core/src/vertical.rs`

**Follow framing (the heart).** With a vertical or square layout, a take
wider than the frame fills the room: the canvas minus the padding, about
928x1768. It is seen through a window of the frame's shape at the take's
full height.
- The window aims at the zoom's fixed point while a zoom holds on one.
  Otherwise it aims at the camera copy of the pointer (3.2 rad/s).
- It holds still while that aim stays within 22% of the window's width (or
  height) of its centre: the dead zone.
- Then it re-aims, and the aims are glided by a critically damped spring at
  4 rad/s, run forwards and backwards. A pan takes about 1.5 s, starts about
  0.5 s before the move and settles about 1 s after it. There's no jitter and
  no drift.
- Zooms keep 60% of their depth (2x becomes 1.6x), since the window is
  already close.
- `Camera.window` (both Kits) carries the window's shape. `viewport`,
  `project`, the source rect, the cursor and ripples, `contentPoint` and
  `cameraCentre` all follow from it unchanged.
- A take no wider than the frame is shown whole, as before.

**Safe area.** `safeArea(canvasWidth:canvasHeight:) -> CGRect` (Swift, a
global function) and `vertical::safe_area(w, h) -> Rect` (Rust; in wasm it is
`safeArea`).
- On a tall canvas (height above 1.25x the width) it leaves out the top 12%,
  the bottom 20% and 8% of each side, rounded to whole pixels.
- Any other canvas gets the whole canvas.
- On a tall canvas, texts are placed inside it: `Renderer.inSafeArea`
  (Swift) and `plan::in_safe_area` (Rust) map a text's 0..1 place into the
  safe rect. The captions agent can use the same function.
- `SafeArea.captionBand` / `vertical::CAPTION_BAND` (10% of the height) is
  the bottom of the safe area kept for captions.

**Camera bubble (vertical only).** The bubble is 1.5x bigger, capped so it
fits the width. A bottom corner sits in the lower third, with its bottom on
the safe area's lower edge less the caption band. A top corner sits just
under the safe area's top.

**Backdrop, padding, corners.** These keep their fractions of the short side
(76 px padding at 1080 wide). The corner radius is relative to the frame's
short side, and the shadow is unchanged. A `none` backdrop fills the whole
phone frame.

**UI, Mac.**
- A **Shape** section at the top of the inspector: Landscape / Vertical /
  Square, with a one-line hint. Output's size and aspect pickers show only in
  landscape.
- The preview draws the phone bands faintly (a dim wash and a dashed safe
  line) while editing a tall canvas, in `SafeAreaGuides.swift`. They are
  never in the export.
- While framing (Hide & crop), the take is shown whole.
- **Record Vertical** is in the ring's right-click menu, and Home has an icon
  toggle (portrait or landscape rectangle). Both are remembered in
  UserDefaults `recordVertical`. A new recording's edit starts vertical;
  added takes don't change the layout.
- `MonetShot --aspect <rec.reel> landscape|vertical|square` and
  `MonetShot --vertical <rec.reel>`.

**UI, desktop (Tauri).** The same pieces as the Mac:
- A Shape section in `Inspector.svelte`, and `SafeGuides.svelte` in the
  preview.
- Framing shows the take whole.
- Record Vertical is a tray check item, a small shape toggle on the idle pill
  (a wide glyph that turns tall) and an icon on Home. It is the
  `bar_toggle_vertical` command and `BarState.vertical`, stored in
  config.json as `recordVertical`.
- When a new recording finishes, `recorder.rs` sets its edit to vertical.
- CLI: `monet-shot --aspect <rec.reel> <layout>`, `--vertical <rec.reel>`
  and `--render <rec.reel> <out.mp4>`. They run without starting the app.

## How it was proven

**Fixtures** (from the Swift Kit, checked by Rust). They use their own random
stream, so every older fixture is byte-identical.
- `shared/fixtures/vertical.json` holds:
  - canvas sizes for every layout, with byte-identical edit.json
  - safe areas
  - window shapes
  - texts in the safe area
  - six whole layouts, with the follow camera sampled every 0.05 s and
    compared to 1e-9:
    - default Retina with auto zooms
    - fixed-focus zooms
    - two takes with a crop, one of them portrait
    - `none` backdrop with a big bubble
    - square
    - a take with no cursor
- `shared/fixtures/render/vertical.json` holds three 1080x1920 / 1080x1080
  reference frames from the Mac Renderer: `vertical-paper`,
  `vertical-zoom-caption-camera` and `square-follow`.

Tests:
- `desktop/crates/core/tests/vertical.rs` (5 tests), plus a calmness test.
- `desktop/crates/export/tests/render.rs`: the export painter against the
  vertical frames.
- The WebGL preview's `fixtures-test.html` runs the vertical cases too.

**Mac (this machine).**
- `swift run MonetShotChecks`: all 148 pass, including 4 vertical checks:
  - layout round trip and back to landscape byte for byte
  - the safe area
  - follow framing: the window is tall, a wobble doesn't move it, it ends on
    the right inside the picture, it never pans faster than 0.9 picture
    widths a second, and it is above 0.9 output px per recorded px (0.98 here)
  - bubble and texts inside the safe area
- `fixtures.sh` regenerates with only the new files.
- A real recording (`2026-11-01 21.23.59.reel`, Retina 3456x2006, copied to
  scratch) went through `MonetShot --vertical`, then `--render`. The result
  is H.264 1080x1920, 606 frames at 60 fps, 10.1 s, in 4.1 s.
- I looked at the frames: the site's serif headings, body text and the small
  metadata lines are crisp and legible at phone size. The window followed the
  cursor and the zoom.
- Screenshots in `docs/v0.2/status/vertical/`:
  - `mac-export-6s.jpg` (an export frame)
  - `mac-frame-9s.jpg` (a `--frame` still)
  - `mac-editor.jpg` (the editor: tall preview with guides, Shape section)
  - `mac-home.jpg` (Home with the shape toggle on Vertical)

**Windows (CI VM, `windows-run` stage 9).**
- `monet-shot --vertical` runs on stage 1's real WGC take, then `--render`
  gives a 1080x1920 H.264 export. Frames at 1, 2.5 and 4 s are uploaded:
  `vertical-frame-*.png` in the `windows-run` artifact.
- The debug exe then opens it with `devchecks/vertical.js`, which checks:
  - the canvas is 1080x1920 and the window is tall
  - the frame fills the phone and the scale is the same on both axes
  - the safe area, the guides and the Shape control showing Vertical
  - Landscape restores the landscape canvas with its keys untouched, with no
    guides and the take whole
  - Vertical comes back
  - Record Vertical flips and flips back
- Screenshot: `9-editor-vertical.png`.
- Stage 3 (preview vs the Mac's frames) includes the three vertical frames.

**Linux and Arch.** `cargo test --workspace` (core, export painter vs the
vertical frames) and the Tauri/PKGBUILD builds. hyprland-run runs as before.
It has no vertical-specific stage.

## Not proven
- No vertical recording was started from the menu bar or the pill with Record
  Vertical on. The setting flips (Windows devcheck) and the finish path is
  small, but a live recording with the toggle on wasn't driven.
- The pill's toggle and the tray check item weren't clicked. The command
  they call is tested.
- Record Vertical on Linux/Omarchy wasn't run (no hyprland-run stage).
- The desktop's Home toggle is only covered by the shared command.
- No phone was used: legibility was judged from 1080x1920 frames looked at
  on this Mac.
- Recording a window or region already cropped to a tall shape (the brief's
  optional item) wasn't built. A tall window recording is shown whole in
  vertical, which covers it.
- 4K vertical: vertical is fixed at 1080x1920 and the output-size picker is
  hidden.

## Merge notes (music, captions)
Files most likely to conflict:
- `Sources/MonetShotKit/Model/Project.swift`: `layout` added after `format`
  in EditDoc, in the decoder and in `canvasSize`.
- `desktop/crates/core/src/model.rs`: `layout` after `format`, and
  `canvas_size`.
- `Sources/MonetShotKit/Render/Renderer.swift`: TakeLook (`follow`),
  `bubbleRect`, and `withTexts` (texts go through `Renderer.inSafeArea`;
  captions drawn there should use `safeArea` too).
- `desktop/crates/core/src/plan.rs`: Look, `texts()`, `bubble_rect`, and
  `in_safe_area` / `PHONE_BUBBLE` added before `hides`.
- Inspectors: `InspectorView.swift` (a `shapeSection` first in the body list;
  the Output section) and `Inspector.svelte` (a Shape section first; Output).
- `MonetShotChecks/main.swift`: four checks inserted after "config
  round-trips".
- `shared/tools/fixtures/main.swift`: `cam()` writes `window` only when it
  isn't 1, and a new "Vertical and square" block before the sync stamp.
  After merging all three, run `shared/tools/fixtures.sh`; it should change
  nothing of mine.
- `CommandLineMode.swift`: `--aspect` / `--vertical` next to `--format`.
- PARITY.md: one row before "Export MP4". README: a Shape bullet before
  "Space plays", and a CLI line.
- Desktop app: `bar.rs` (BarState.vertical), `lib.rs` (`Bar::new(...,
  vertical)`, the handler list, `edit_cli`), `tray.rs`, `settings.rs`,
  `recorder.rs`, `ipc.ts`, `mock.ts`, `Pill.svelte`, `Home.svelte`,
  `store.svelte.ts` (replan), `core.ts`, `plan.ts`, `core-wasm/src/lib.rs`
  (`safeArea`).
- `windows-run.ps1`: stage 9, and stage 3 counting `vertical.json`.

For captions: the safe area is `safeArea(canvasWidth:canvasHeight:)` (Swift)
and `vertical::safe_area` / wasm `safeArea` (Rust). On a tall canvas, keep
captions in the safe area's bottom `CAPTION_BAND` (10% of the height); the
vertical bubble sits above it.
