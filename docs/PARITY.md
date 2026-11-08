# Keeping Monet Shot the same everywhere

There are three products (Mac, Linux incl. Omarchy, Windows) but only **two
codebases**: Swift for the Mac (`Sources/`), Tauri for Linux and Windows
(`desktop/`). Linux and Windows can't drift from each other; they are the
same code. The work is keeping Swift and `desktop/` in step.

## 1. The format is the contract

`docs/spec.md` and the `.reel` folder (meta.json, cursor.json, edit.json,
take-N/) are the shared truth. Both sides write sorted-key JSON, ISO-8601
whole-second dates, and decode tolerantly (every new field has a default).
**A new field lands in both codebases in the same change**, or the side that
lacks it must round-trip it untouched (desktop keeps unknown keys).

## 2. Golden fixtures enforce behaviour

`shared/tools/fixtures/` compiles the Swift `MonetShotKit` sources as-is
(swiftc, no Package change) and dumps the answers to fixed questions:
camera at t, smoothed cursor, auto-zooms for a click log, keptClips, TimeMap,
ClipEdits, privacy rects, music envelope, canvas sizes, frame layout. Output
goes to `shared/fixtures/*.json`. The Rust core's tests read those files and
must match.

So when the Mac changes behaviour: regenerate fixtures, the Rust tests go
red, port until green. Nobody has to remember.

`shared/fixtures/render/` holds reference frames rendered by the Mac
renderer; the export painter is compared to them with a tolerance.

Regenerating is deterministic, so CI can diff: two runs of
`shared/tools/fixtures.sh` give byte-identical files. Inputs come from a
fixed LCG, every id in an edit is fixed, and the reference frames are drawn
with CoreImage's software renderer (each is rendered twice per run and the
tool warns if the two differ).

## 3. Shared assets live once

`Resources/` (backdrops + credits, app icon) is canonical. The desktop
bundle reads from it at build time; nothing is copied by hand.

## 4. The ledger

The table below is the feature-by-platform status. Every change that adds
or changes a feature adds or updates a row. A row that is ✅ on one side and
not the other is the to-do list.

`scripts/parity-diff.sh` (desktop tools) prints Swift changes since the
commit in `shared/LAST_SYNC`, so porting starts from a list, not memory.

## 5. One version, one release

`VERSION` at the repo root is the only version. The release script stamps it
into Info.plist, `tauri.conf.json`, Cargo and the PKGBUILD, and the three
builds are tagged and released together.

## 6. CI watches all three

One GitHub Actions workflow: macOS (swift build + MonetShotChecks + fixture
freshness: regenerate and `git diff --exit-code shared/fixtures`), Ubuntu and
Arch (cargo test + Tauri build + PKGBUILD), Windows (cargo test + Tauri
build). A red fixture check means someone changed one side only.

## Later, if wanted

The Tauri app also runs on macOS. Once it matches the Swift app, the Mac
could move to it and there'd be one codebase. Not now: the Swift app is the
reference and the better Mac citizen today.

## Ledger

✅ works, verified on that platform's own hardware · 🟡 built and tested
(unit tests, this Mac's dev backend, Linux containers, Windows
cross-compile), not yet run on that platform's hardware · 🚧 in progress ·
⏳ not built. 🐳 "Hyprland in a container" (Omarchy): run by the `hyprland-run` job, real Hyprland 0.57 on a vkms virtual display with Omarchy's own config, in an Arch container on GitHub's Ubuntu VM; not real hardware (`docs/porting/status/omarchy-run.md`). "CI VM" (Windows): run by the `windows-run` job on GitHub's
Windows Server 2025 VM, a real desktop without a GPU
(`docs/porting/status/windows-run.md`). Desktop rows as of 2026-11-03, from
`docs/porting/status/`.

| Feature | Mac | Linux | Omarchy | Windows |
|---|---|---|---|---|
| Tray/menu bar ring, 3-2-1, hold-to-stop | ✅ | 🟡 | 🐳 Hyprland in a container: the omarchy-shell widget (4.0.6) shows the 3-2-1 and the time; SUPER+ALT+R pressed (uinput) starts and stops · the Waybar module (3.8.4) shows them too; the pill floats and pins at 180x34, top centre, and stays out of the take with a bar up · 🟡 the widget itself not clicked | ✅ ring tap via `monet-shot toggle` → our picker → 3-2-1, and hold-to-stop on the pill with the real mouse (a short click doesn't stop) (CI VM) · 🟡 tray icon + menu not clicked |
| Record display / window | ✅ | 🟡 portal: the shared ashpd/PipeWire path has recorded under xdph (see Omarchy); GNOME's and KDE's portals not run | 🐳 Hyprland in a container: display through the ScreenCast portal (xdph, Omarchy's xdph.conf; the picker answered by a script), restore token skips the picker after the first take · 🟡 window pick | ✅ display and window (CI VM: WGC on Server 2025; a window picked in our picker records at its own size; the pill is kept out of the take) |
| Own cursor log + clicks | ✅ | 🟡 evdev/X11 | 🐳 Hyprland in a container: Hyprland IPC pointer, matches the picture to 0 px; uinput clicks via evdev | ✅ (CI VM: GetCursorPos samples + WH_MOUSE_LL clicks from injected input) |
| Pause = clip (double-tap Shift) | ✅ | 🟡 | 🐳 Hyprland in a container: double-tap Shift (uinput keyboard) pauses and resumes | ✅ (CI VM: injected double-taps with another app focused and the pill up → one cut matching them) |
| Home (cards, import, reveal, trash) | ✅ | 🟡 | 🐳 Hyprland in a container: cards + thumbnails, open by clicking, trash (freedesktop Trash), reveal (folder via xdg-open when there's no FileManager1) · 🟡 import | ✅ cards + thumbnails, open by clicking, reveal (Explorer), trash (Recycle Bin) (CI VM; reveal/trash through the context menu's commands, the native menu itself not clicked) · 🟡 import |
| Editor preview (same frame as the export) | ✅ | 🟡 (WebGL2 in WebKitGTK: 0.06–0.82/255 vs the Mac's frames; Mac HEVC takes play) | 🟡 (as Linux) · 🐳 Hyprland in a container: the editor runs (WebKitGTK, editor.js 27/27) | ✅ (CI VM, WebView2: 0.04–0.76/255 vs the Mac's frames; an HEVC take plays via the H.264 proxy) |
| Auto-zoom + zoom editing | ✅ | 🟡 | 🐳 Hyprland in a container: Z, Delete, undo/redo, drag (editor.js) | ✅ (CI VM: auto-zoom from recorded clicks; Z, Delete, undo/redo, drag) |
| Clips: split, trim, move, add take, undo | ✅ | 🟡 (split/trim/move/undo clicked through in WebKitGTK; add take/footage wired, not clicked through) | 🐳 Hyprland in a container: split, trim, move, undo, add a video, record a new take through the portal (home.js) | ✅ split, trim, move, undo, add a video (its command; the file dialog not driven), record a new take through the picker (CI VM) |
| Backdrops (colours, 20 paintings, own image, blur) | ✅ | 🟡 | 🐳 Hyprland in a container: colours + paintings · 🟡 own image, blur | ✅ colours + paintings (CI VM) · 🟡 own image, blur |
| Cursor looks (5) + tints + ripples | ✅ | 🟡 (tag in Inter Bold) | 🐳 Hyprland in a container: Dot look · 🟡 the rest (tag in Inter Bold) | ✅ Dot look in preview + export (CI VM) · 🟡 the rest (tag in Inter Bold) |
| Hide (blur/pixelate/cover) & crop | ✅ | 🟡 | 🐳 Hyprland in a container: hide box drawn, crop corner dragged | ✅ (CI VM: hide box drawn and in the export; crop corner dragged) |
| Camera: over video, just me, with screen | ✅ | 🟡 (no live camera yet) | 🟡 (no live camera yet) | 🟡 (no live camera yet) |
| Music browser + ducking | 🚧 WIP | 🟡 (seen running in WebKitGTK; preview audio via media_url) | 🟡 | 🟡 |
| Clip speed (¼×–4×) + fades | ✅ (2026-11-03: preview, export 11.87 s at 0.85× as planned) | 🟡 (fixtures `clip_speed.json`; export matches the Mac's frame for frame, 38 dB PSNR, run on macOS; preview checked in a browser) | 🟡 | 🟡 (cross-compiled) |
| Text overlays (title / caption / label; fade, rise, pop, word by word) | ✅ | 🟡 (fixtures `text.json`; layout matches CoreText to 0.05 px; reference frames `charcoal-texts*`; preview checked in a browser) | 🟡 | 🟡 (cross-compiled) |
| Formats (clean, fast, melancholic, cinematic) | ✅ (`--format`) | 🟡 (fixtures `formats.json`: byte-identical edit.json) | 🟡 | 🟡 (cross-compiled) |
| Vertical / square (follow framing, safe area, phone bubble, Shape, Record Vertical, `--aspect`) | ✅ (2026-11-08: a real recording made vertical with `--vertical`, `--render` → H.264 1080×1920, frames looked at; MonetShotChecks) | 🟡 (fixtures `vertical.json` + `render/vertical.json`: camera every 0.05 s to 1e-9, the export painter against the Mac's 1080×1920 frames; preview checked in the fixtures page) | 🟡 | ✅ (CI VM, windows-run stage 9: `--vertical` + `--render` → 1080×1920, frames grabbed; the editor's Shape, guides, back to Landscape, Record Vertical via devchecks/vertical.js) |
| Export MP4 | ✅ | 🟡 (matches the Mac's export, run on macOS; in-app export run in the Arch container) | 🐳 Hyprland in a container: Ctrl+E in the editor → H.264 1080p, ffprobed | ✅ (CI VM: Ctrl+E in the editor → H.264 1080p, ffprobed) |
| Install | Homebrew | 🟡 AppImage/deb (config) | 🐳 Hyprland in a container: install.sh on a live Omarchy 4.0.6 session (rules, SUPER+ALT+R, plugin enabled; the pill floats, pins, 180x34 top centre) and 3.8.4's Waybar module · 🟡 PKGBUILD (srcinfo ok), not installed from | ✅ NSIS (CI VM: silent install, record with the installed exe and its ffmpeg sidecar, silent uninstall) |
