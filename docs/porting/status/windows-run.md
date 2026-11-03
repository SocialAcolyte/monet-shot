# ms-win status: the Windows build run on a real Windows desktop

Hardware: GitHub's `windows-latest` VM: Windows Server 2025 Datacenter
(build 26100), an interactive desktop at 1024×768, WebView2, no GPU (Microsoft
Basic Render Driver; D3D11 "hardware" device creation succeeds on it).

The job is `windows-run` in `.github/workflows/desktop.yml`. It runs on every
push, beside `windows`, and builds its own exes: release with
`tauri build --no-bundle`, plus the debug exe and core's `plan_dump`. It
then runs `desktop/tools/windows-run.ps1`, with `windows-hevc-check.js` for
the HEVC stage. It fails on any of stages 1–5. The `windows-run` artifact
holds the app log for each stage, the take, `export.mp4`, screenshots of
each stage and `vite.log`. The job takes about 26 min, mostly the two builds.

## Done (green on run 41596260985, 2026-11-03)
1. **Record** (release exe, `MONETSHOT_DEMO_RECORD=1 MONETSHOT_DEMO_STOP=5`).
   The pointer circles via SetCursorPos, with two SendInput clicks mid-take.
   - WGC records the display: `screen.mp4` is H.264 1024×768, 303 frames,
     5.05 s.
   - `cursor.json` has 148 samples (127 distinct x) and both clicks.
   - `meta.json` loads with core's `Project::load` (plan_dump).
2. **Editor** (debug exe on the Vite dev server, WebView2), on a copy of
   the take with `devchecks/editor.js`: 27 ok, 0 failed. That covers zooms,
   split, trim, undo, ruler, framing hide + crop, swatches, painting
   gallery, padding, cursor look, output, play, save and export.
3. **Fixtures**: all 10 cases, mean 0.04–0.76/255 (worst paper-default
   0.76). That matches the Mac's WKWebView (0.03–0.76) and Linux (0.06–0.82).
4. **HEVC**: the take was re-encoded with libx265 (`hvc1`, as the Mac
   records). WebView2 can't show it, so the editor falls back to
   `video_proxy`. The picture appeared after 1.3 s and playback ran (clock
   2.01 s, video 2.03 s after 2 s).
5. **Export**: the editor check's Ctrl+E took 21 s and produced H.264
   1920×1080, 301 frames, 5.02 s. Its frames show the painting backdrop,
   the zoom, the Dot cursor and the hide box.

## Found and fixed
- `app/src-tauri/src/windows.rs` (Windows only): `open_editor` passed
  `fs::canonicalize`'s verbatim form (`\\?\D:\…`) to the editor. The editor
  showed that path, exported next to it and handed it to Explorer. Drive
  paths now drop the prefix, and windows-run fails if it comes back.
- `app/ui/src/main.ts`, `app/vite.config.ts` (shared, dev builds only):
  Vite's `/@fs` needs `/@fs/C:/…`. The devscript path and
  `__MONETSHOT_REPO__` were raw `C:\…`, so devscripts and dev pages could
  not load on Windows.
- `crates/capture/src/win/wgc.rs`: falls back to a WARP D3D11 device when
  no hardware device can be created. The VM didn't need it.
- Reported to the lead, who fixed it in 880f25b: `write_thumb`'s shared tmp
  name raced between two Home refreshes ("thumb …: os error 2").

## Not proved by this job
- **Pill and windows kept out of recordings.** The demo hook turns content
  protection off on purpose, and the take shows the pill.
- **The tray by hand:** the menu, hold-to-stop, our picker, window
  recording, and pause (double-tap Shift).
- **The installer.** NSIS is built by `windows`, but this run uses the bare
  exes with ffmpeg copied beside them.
- **Hardware encoders and GPU paths.** There is no GPU here; the encoder in
  use isn't in the app log (capture logs through `log::`, which goes
  nowhere in the app).
- Camera, music, Home clicks, add take/footage, clip move.
- Windows 10/11 client editions, and DPI scales other than 100%.
