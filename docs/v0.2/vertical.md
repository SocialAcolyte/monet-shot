# You are ms-vertical: videos for phones

Branch `feat/vertical`, worktree `~/Developer/monetshot-wt/vertical`. Read
`docs/v0.2/README.md` first.

## The problem
A screen recording is wide. Put it in a 9:16 frame and it's a strip of tiny
text across the middle of a phone. The editor already has
`EditDoc.canvasAspect` (16:9 default, 0 = match the recording), but nothing
makes a tall video good.

## What to build (Mac and desktop, same edit.json, same pixels)
1. **A Vertical layout.** One choice in the inspector (Landscape 16:9 /
   Vertical 9:16, plus square 1:1 if it falls out for free), and a
   `--vertical` / `--aspect` on the CLIs. Choosing Vertical makes the video
   *read* on a phone:
   - **Follow framing**: the recording is cropped to a tall window that fills
     most of the phone frame and pans to follow the action: the zoom
     segments' targets when zoomed, otherwise the smoothed cursor, with the
     same easing/smoothing the zooms use (no jitter, no constant drift: a
     dead zone, then a glide). This is the heart of the feature; make it feel
     like a person operating the camera.
   - The camera bubble, if there is one, sits where a phone viewer expects it
     (e.g. lower third, larger), and text overlays/captions stay inside the
     phone's safe area (clear of the top ~12% and bottom ~20% that Reels/TikTok
     cover with UI). Expose the safe area as a function the captions agent can
     use (`safeArea(canvas)` in both Kits).
   - Backdrop, padding and corner radius stay sensible in a tall frame.
   - Export 1080x1920 by default.
   - Switching back to Landscape restores the landscape edit untouched.
2. **Vertical at record time.** A "Vertical" option where you start a
   recording (Mac menu bar popover / desktop pill + Home), remembered in
   settings, so a take opens already in Vertical. Optionally (if cheap and
   good) record a window or region cropped to a tall shape.
3. **Preview**: the editor preview shows the tall frame (letterboxed in the
   editor window), with the phone UI safe areas faintly drawn while editing
   (not in the export).

## Parity and proof
- Model + framing math in `MonetShotKit` and `desktop/crates/core` (+ wasm for
  the preview), with new golden fixtures (`shared/fixtures/vertical*.json`
  and reference frames under `shared/fixtures/render`) generated from Swift
  and checked by Rust tests. Add MonetShotChecks cases.
- Export a real vertical mp4 on the Mac (`MonetShot --render` on a recording
  in ~/Movies/MonetShot, or a synthetic one) and on the Windows VM (extend
  `desktop/tools/windows-run.ps1` to export one vertical clip and upload a
  frame grab). Look at the frames yourself (Read the PNGs): text in the
  recording must be legible at phone size.
- UI snapshots of the inspector choice and the tall preview (Mac via the
  snapshot env vars; desktop via the CI runs' screenshots).
- PARITY ledger rows, README section, spec lines.

## Shared seams
You own canvas aspect, framing, the camera bubble's vertical placement and
`safeArea`. The captions agent places captions with your `safeArea`; if it
needs it before you merge, it will copy a stub: message nobody, just keep the
signature `safeArea(canvasWidth, canvasHeight) -> rect` in both Kits.
