# ms-win status: the Windows build run on a real Windows desktop

Hardware: GitHub's `windows-latest` VM: Windows Server 2025 Datacenter
(build 26100), an interactive desktop at 1024×768, WebView2, no GPU (Microsoft
Basic Render Driver; D3D11 "hardware" device creation succeeds on it).

The job is `windows-run` in `.github/workflows/desktop.yml`. It runs on every
push, beside `windows`, and builds its own: the release exe and the NSIS
installer (`tauri build --bundles nsis`), the debug exe and core's
`plan_dump`. It then runs `desktop/tools/windows-run.ps1`, with
`windows-hevc-check.js`, `windows-window-check.js` and
`app/ui/devchecks/home.js` as dev scripts. It fails on any failed check in
stages 1–8. The `windows-run` artifact holds
the app log for each stage, the takes, `export.mp4`, screenshots and
`vite.log`. The job takes about 25 min, mostly the builds.

## Done (all 8 stages green on run 41622844239, 2026-11-03)
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
6. **Install** (NSIS, 119 MB): `/S` installs to `%LOCALAPPDATA%\Monet Shot`
   with an uninstall entry, `ffmpeg.exe`/`ffprobe.exe` beside the app and
   40 backdrop images. The installed exe records a 7 s take using its own
   sidecar (`MONETSHOT_FFMPEG` unset; the app log says `encoder: libx264`).
   - **The pill never takes the focus:** a stand-in "user app" has it, and
     with the pill up the foreground is still that app.
   - **Pause:** with the pill up and the user app focused, two SendInput
     Shift double-taps make one cut (1.91–4.17 s, matching the taps); 4.79 s
     of 7.05 s are kept. No help from the script.
   - **Content protection** (`MONETSHOT_DEMO_PROTECT=1`): in the take, the
     pill's place differs from the bare desktop by a mean of 0.8/255, so the
     pill is not there. In stage 1's take (protection off) it differs by
     140.7, so the check can see a pill.
   - `uninstall.exe /S` removes the app.
7. **Window + hold-to-stop** (debug exe): `monet-shot toggle` (a second
   launch, as Waybar or a hotkey would do) opens our picker. The dev script
   clicks the card of a WinForms window we opened. The take is
   `source: window`, 642×432, the same as the window's DWM frame, and its
   middle is the window's colour (198,89,58).
   - A 0.12 s real-mouse click on the pill's ring leaves the take running;
     a 1.3 s hold stops it.
8. **Home + clips** (`app/ui/devchecks/home.js`, any platform), on a new
   library on C: with "Open me" and "Trash me":
   - Home shows both cards with their thumbnails.
   - Move to Trash removes the card, and the folder is in the Recycle Bin.
   - Show in folder opens Explorer on `recordings`.
   - Clicking a card opens it in the editor.
   - In the editor, add a video makes 2 takes and 2 clips. Record a new
     take goes through our picker, 3-2-1 and recording (stopped with
     `toggle`), and gives 3 takes and 3 clips (`take-3`).
   - Dragging a clip reorders it, and undo puts it back. The 3 takes are
     saved.
   - Reveal and trash use the context menu's commands; the native menu
     itself isn't clicked. Add a video uses the same calls as its handler;
     the file dialog isn't driven.

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
- `app/src-tauri/src/log.rs` (with the lead's OK): the `log` crate's records
  now go to the app log. Ours are logged at info (debug with
  `MONETSHOT_DEBUG=1`), other crates' from warn up. Capture's encoder
  choice, start/stop, pauses and warnings had gone nowhere on every
  platform. `win/input.rs` logs key events at debug.
- `MONETSHOT_DEMO_PROTECT=1` (windows.rs): keeps the pill's content
  protection on under the demo aid, for the protection check.
- **The pill took the focus** (windows.rs, Windows only). Showing it
  activated it despite `focused(false)`, and keys, including double-tap
  Shift, then went to it and never reached the input hook. The pill and
  the camera bubble now get `WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW` and are
  shown with `SW_SHOWNOACTIVATE`. The install stage proves it with another
  app focused.
- **Deadlock building windows from sync commands** (commands.rs). On
  Windows, clicking a Home card left a blank editor and the app hung. Record
  a new take never showed the picker, and Home's New recording button and
  the pill's record button would have hung the same way. Tauri runs sync
  commands on the main thread inside WebView2's IPC callback, and a window
  built there deadlocks. `run_on_main_thread` doesn't help: on the main
  thread, tauri-runtime-wry runs the task at once. These commands are async
  now: `open_recording`, `show_home`, `bar_tap`, `bar_cancel`,
  `bar_toggle_pause`, `bar_stop`, `picker_choose`, `record_take`. The rule
  is in ARCHITECTURE.md's contracts. The lead audited the remaining sync
  commands; none builds a window.

## Open
- Nothing known. Standing by.

## Not proved by this job
- The tray icon and its menu (not reachable from the script; `toggle` takes
  the same path as the ring's tap).
- Physical keyboard and mouse: all input was injected with SendInput.
- Hardware encoders and GPU paths (no GPU here: libx264, Basic Render
  Driver).
- The native context menu and file dialogs (their commands are tested);
  import from Home.
- Camera and music.
- Windows 10/11 client editions, and DPI scales other than 100%.
