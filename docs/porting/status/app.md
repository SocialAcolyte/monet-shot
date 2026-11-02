# ms-app status

## Done
- **1. Scaffold**: `desktop/app` = Tauri 2 (`src-tauri`, crate `monet-shot`)
  + Svelte 5 + TS + Vite (`ui/`), in the workspace. Icons derived from
  `Resources/AppIcon.icns` by `npm run icons` (macOS only; outputs kept in
  `src-tauri/icons`). Backdrops bundled from `../../../Resources/Backdrops/`.
  Fonts: SF Pro Rounded where present, else bundled Nunito (OFL) for
  SwiftUI's `.rounded`. Icons: `@lucide/svelte` for SF Symbols.
- **2. Tray + pill**: record state machine (port of `MenuBarModel`) on
  `monetshot-capture`; tray icon drawn per state (ring, 3-2-1 pill, clay
  ring, paused dot; time as the tray title on macOS/Linux, tooltip on
  Windows); right-click menu as the Mac's (Record…/Pause/Stop, Record My
  Camera Too, Open Monet Shot, Recent, Open Recording…, Show Recordings,
  Quit); pill window (3-2-1, rolling time, pause, press-and-hold stop with
  drag-away cancel); our picker window (Windows/macos-dev); camera bubble
  during the 3-2-1; status published for Waybar; CLI `status`/`toggle`/
  `pause` via single-instance. Contract: `contracts/ipc.md`.
  Verified on this Mac (macos-dev): pick → 3-2-1 → record → stop → editor
  opens, files written. Tray icons rendered and checked.

- **3. Home**: cards with their thumbnail (the Mac's shared `thumb.jpg`
  when fresh; else a raw ffmpeg frame in our own cache, never written into
  the recording), title + "0:42 · 3 clips · 2 takes", native context menu
  (Open, Show in Finder/Explorer/Files, Move to Trash/Recycle Bin via
  `trash`), New recording, empty state, refreshes on focus and on
  `library-changed`. Verified with Connor's real recordings (read-only).
  Thumbnails rendered with their backdrop by `monetshot_export::write_thumb`
  (raw frame only if that fails); Import video via `imports`.
- **4. Editor.** Feature-complete and checked on this Mac (WKWebView) and on
  Linux (WebKitGTK, ms-capture's run) on a copy of a real recording:
  - `MONETSHOT_DEV_SCRIPT=…/ui/devchecks/editor.js` drives it (keys, pointer
    drags, clicks): 29/29 ok — Z/Delete/undo/redo, S split, ←/→ ⇧, ruler
    scrub, clip trim + reorder (+ undo), zoom drag, B framing + draw a hide
    box, R crop + corner drag, Esc, backdrop swatches + painting gallery,
    Padding slider, cursor look, Output, Space play/pause, edit.json saved,
    Ctrl+E export to the end. The exported MP4 shows every edit. Export
    time for that 10.7 s (HEVC 3456×2006 take, 1080p out): ≈20 s (the
    export crate builds at opt-level 2 in dev too; ms-core's release
    example: 19.7 s).
  - Painter vs the Mac's reference frames (`ui/fixtures-test.html`, run in
    the app with `MONETSHOT_DEV_PAGE=fixtures-test.html`): mean
    0.03–0.76/255 on all 10 cases (gamma-space bilinear as CoreImage,
    two-pass Lanczos-3 shrink in linear light).
  - HEVC (Mac takes) fallback: a take this engine can't decode switches to
    ms-capture's H.264 `video_proxy`, with a notice over the preview.
  Camera + music UI: ms-capture (camera/, music/, media.rs).
  Add a video/recording (`add_footage`) and Record a new take are wired but
  not clicked through.

## Standing by (lead, 2026-11-02): no new work until asked.

## Linux (ms-capture's Xvfb run, WebKitGTK 4.1 + llvmpipe, installed .deb)
- Fixtures: 0.06–0.82/255 on all 10 cases (same as the Mac).
- Check script: 29/29. The Mac's HEVC take previews directly (no proxy)
  through `media_url`; playback runs, auto-zoom and cursor show; the gallery
  thumbnails load; dev pages run without a hardcoded repo path.
- Not judged there (no compositor): the pill's size/position fix — needs
  Hyprland. The light line at the window bottom was openbox's own handle.

## To do / not verified
- Pill on Hyprland/Omarchy (rules by ms-capture) on a real desktop.
- Windows: `cargo xwin check -p monet-shot --target x86_64-pc-windows-msvc`
  passes; WebView2 not run.
- Linux: `cargo check -p monet-shot` passed in the Arch container (before
  the export wiring). Linux builds and runs are ms-capture's (one Docker
  job at a time); their Arch build + Xvfb run covers the app.
- Live webcam flows (needs Connor), the Lanczos cost on weak Linux GPUs
  (falls back to nothing yet; may want bilinear while playing).
