# ms-capture status

## Done
- 1. Contract: `docs/porting/contracts/capture.md` (lead approved; preview 30 fps).
- Shared crate `desktop/crates/capture` (monetshot-capture), on monetshot-core; 18+ unit tests:
  pointer log + double-tap Shift (CursorTracker.swift port), CFR encoder pipe (tested with real
  ffmpeg), ffmpeg locate + hw encoder probe, session/take writer (pauses -> cuts, autoZooms,
  stop-bar trim, new takes), shared camera (preview JPEG ~30 fps + file), Waybar status.
- 5. macos-dev backend (early, for ms-app). Verified with a real recording on this Mac.
- 2. Windows backend: WGC (cursor/border off), own picker sources + thumbnails, DPI v2,
  GetCursorPos 120 Hz, WH_MOUSE_LL/WH_KEYBOARD_LL. `cargo xwin check`/clippy clean.
- 3. Linux backend written: ashpd portal (restore token, Metadata/Hidden cursor), PipeWire
  (SHM, BGRx/BGRA/RGBx/RGBA, cursor meta), Hyprland IPC pointer (monitor/client mapping,
  scale, reserved bar), evdev clicks/keys (+ touchpad tap), X11 fallback. `forget_pick()`.
- Tools: `desktop/tools/docker-arch.sh` (+ arch/ubuntu Dockerfiles), `stamp-version.sh`
  (+ `--check`), `parity-diff.sh`; `VERSION` = 0.1.1 (all files agree).
- 7. CI `.github/workflows/desktop.yml` written (not pushed).
- 6 (part): PKGBUILD, Linux deb/AppImage overlay, Windows NSIS overlay + ffmpeg sidecar fetch.

- 3. Linux verified: 20/20 tests + clippy clean on Arch and Ubuntu containers.
- 6. Omarchy 4 (omarchy-shell plugin, Lua rules, SUPER+ALT+R) and Omarchy 3 (Waybar, hyprlang);
  install.sh tested install/idempotent/uninstall on Omarchy's real v3.8.4 and v4 configs;
  PKGBUILD validated (makepkg --printsrcinfo).
- Editor camera + music (assigned by the lead, split agreed with ms-app):
  src-tauri/src/media.rs (+ camera.rs: remembered device), ui/src/editor/camera/*
  (flow, overlay, camera bar, inspector section, corner picker, lane menu),
  ui/src/editor/music/* (browser + preview, artwork, inspector section, snippet picker,
  use/remove/credit, wave+grid). svelte-check 0 errors, vite build ok, media tests incl. a
  real library song (108 bpm grid). ipc.md "Editor media" section.

## Linux run (lead's assignment), done 2026-11-02
- Arch x86_64 under Xvfb/openbox (tools: run-arch.Dockerfile, linux-run-*.sh, linux-video-diag.js,
  linux-range-server.py). Screens: docs/porting/screens/linux/.
- Works: build, UI, WebGL2 on llvmpipe (fixtures 0.06–0.82/255, = Mac), devchecks 28/29, export.
- Found + fixed (mine): asset:// can't feed WebKitGTK <video>/<audio> → media_url loopback server
  (Range, CORS, tokens; tested); music preview uses it. wasm-bindgen exact-version install for
  PKGBUILD/CI. HEVC needs gst-libav (confirmed decoding).
- Sent to ms-app: <video> via media_url + crossOrigin on Linux; gallery thumbs broken in prod
  build; fixtures-test.html hardcoded path; pill size/position on X11; bottom-edge line.

- media_url hardened (lead's review): random port, 244-bit OS-random tokens per file and per
  window, revoked on window close (`media::release(label)`) or `media_release`; Host must be
  127.0.0.1:<port> (DNS rebinding); CORS only for tauri://localhost, http(s)://tauri.localhost
  (+ the dev server in debug builds), other Origins 403; exactly /<token>/<name>, no query.
  Tests: serves_registered_files_with_ranges, refuses_what_it_should (7/7 media tests green).

- Linux re-run (installed .deb tree, Arch container) after ms-app's fixes: preview plays the
  Mac's HEVC take via media_url (no proxy needed with gst-libav), playback advances, devchecks
  29/29, gallery thumbs fixed (deb carries Backdrops+thumbs and Music). "Bottom line" was
  openbox's window handle, not the app.

## Doing
- Nothing assigned. Left for real hardware: a portal recording (Linux/Omarchy), WGC recording
  (Windows), the live camera (Connor's Mac first), the pill under Hyprland.

## Not verified
- Camera recording on this Mac (would switch on Connor's webcam; do it with him), incl. the
  editor's "Over the video" / "Just me" flows end to end.
- Editor camera/music UI not yet looked at in a running app window by me (ms-app runs the app).
- Real Windows/Linux recording (no hardware here): compile-checked only.
