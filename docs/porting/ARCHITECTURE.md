# Monet Shot for Linux, Omarchy and Windows

The Mac app (Swift, `Sources/`) stays as it is. Linux, Omarchy and Windows
share **one** new codebase in `desktop/`, built on Tauri 2: a Rust core and
a web UI. Omarchy is Linux plus first-class Hyprland/Waybar integration, not
a separate build.

Goal: **full parity** with the Mac app (see `docs/spec.md` and the README):
tray ring, 3-2-1, record display or window with our own cursor log, pause
clips, Home, editor with auto-zooms, clips, backdrops (incl. the 20
paintings), cursor looks, hide & crop, camera, music, export, import.

## Layout

```
desktop/
  Cargo.toml                 workspace (members: crates/*, app/src-tauri)
  crates/
    core/        [core]      pure Rust, no I/O beyond files; compiles to wasm32
                             .reel model + JSON (byte-compatible with the Mac),
                             TimeMap/ClipEdits, CameraMath/SmoothTrack/auto-zoom,
                             Privacy, Camera model, MusicEnvelope, Music catalog
                             parsing, FramePlan (what to draw for output time t)
    core-wasm/   [core]      wasm-bindgen wrapper: the UI's preview gets the
                             same FramePlan the export uses
    export/      [core]      CPU painter (tiny-skia) for a FramePlan +
                             ffmpeg decode -> paint -> encode pipeline, audio
                             (mic, camera voice, music with ducking), import probe
    capture/     [capture]   Recorder trait + backends:
                             windows (Windows.Graphics.Capture, GetCursorPos, WH_MOUSE_LL)
                             linux (xdg-desktop-portal ScreenCast + PipeWire,
                                    cursor: Hyprland IPC > PipeWire cursor meta > X11,
                                    clicks: evdev > X11 XInput2 > none)
                             macos-dev (ffmpeg avfoundation; dev loop only)
                             camera + mic (ffmpeg v4l2/pulse, dshow)
  app/           [app]
    src-tauri/               tray, windows, commands, state, paths, log
    ui/                      Svelte 5 + TS + Vite: pill, Home, Editor
                             (WebGL2 preview painter, timeline, inspector,
                             framing, camera overlay, music browser)
  packaging/     [capture]   omarchy/ (Waybar module, Hyprland rules + binds,
                             PKGBUILD), linux (AppImage/deb), windows (NSIS, ffmpeg sidecar)
  tools/         [capture]   docker-arch build/check, windows cross-check
shared/          [core]      fixtures generated from the Swift Kit (see PARITY.md)
Resources/                   SHARED assets, canonical for all apps (Backdrops +
                             credits.json, AppIcon). Desktop bundles from here.
```

`[name]` is the owning agent. Only the owner edits files there; ask the
owner (SendMessage) for changes. The workspace `desktop/Cargo.toml` is
owned by **core**; app adds its `app/src-tauri` member line itself.

## Key decisions

- **One brain, two painters.** `core::plan(project, t) -> FramePlan` decides
  everything about a frame (canvas, backdrop, frame rect, corner radius,
  shadow, source crop + camera transform, blur boxes, cursor sprite +
  position + scale, ripples, camera bubble). The preview (WebGL2, in the
  webview, sources from `<video>`) and the export (tiny-skia in Rust,
  sources from ffmpeg) are thin painters of that plan. Same plan, same picture.
- **Same files as the Mac.** A take is the same `.reel` folder. The desktop
  records `screen.mp4` (H.264) and sets `meta.video = "screen.mp4"`, so a
  recording made on Windows opens on the Mac and vice versa.
- **ffmpeg** does decode/encode: system package on Linux/Arch, bundled
  sidecar on Windows. Hardware encoders when present (nvenc/qsv/amf/vaapi),
  libx264 otherwise.
- **Paths.** Recordings: Linux `$(xdg-user-dir VIDEOS)/MonetShot`, Windows
  `%USERPROFILE%\Videos\MonetShot`. Config/state: `dirs::config_dir()/MonetShot`.
  Logs: `dirs::data_local_dir()/MonetShot/logs`. `MONETSHOT_HOME` overrides all,
  as on the Mac.
- **Look.** Insomnia-styled, same as the Mac (colours, type, motion). Copy
  values from `Sources/MonetShot/UI` and the Editor views, don't invent.
- **No Wayland global pointer?** Hyprland IPC gives it (Omarchy). Elsewhere
  use PipeWire cursor metadata from the portal stream. If neither: record,
  draw no cursor, auto-zoom falls back to none, say so in the editor.

## Contracts (written by their owner, read by everyone)

- `docs/porting/contracts/frame-plan.md`: core, first thing.
- `docs/porting/contracts/capture.md`: capture, first thing.
- `docs/porting/contracts/ipc.md`: app (Tauri commands/events).
- **Tauri commands that may create a window must be `async`.** A sync
  command runs on the main thread inside WebView2's IPC callback, and
  building a WebView2 window there deadlocks on Windows: it comes up blank
  and the app hangs. `run_on_main_thread` is not enough from a sync
  command, because on the main thread tauri-runtime-wry runs the task at
  once. (Found by `windows-run`; WebKitGTK and WKWebView don't hang, so
  Linux and the Mac won't catch it.)

## Working rules

- Don't touch `Sources/`, `Package.swift`, `scripts/`, `Resources/Music/`:
  Connor has uncommitted Mac work in progress there. Read freely.
- Don't commit or push. Connor/the lead commits.
- Status: keep `docs/porting/status/<you>.md` current (done / doing / blocked).
- Talk to each other with SendMessage (ListAgents shows `ms-core`,
  `ms-capture`, `ms-app`). The lead session is `stylefeatures-d1`.
- Verify what you can on this Mac: `cargo test` for pure crates, Docker Arch
  container for Linux builds, `cargo check --target x86_64-pc-windows-msvc`
  (cargo-xwin) for Windows. Say plainly what could not be verified.
