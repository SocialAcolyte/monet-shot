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
⏳ not built. "CI VM" (Windows): run by the `windows-run` job on GitHub's
Windows Server 2025 VM, a real desktop without a GPU
(`docs/porting/status/windows-run.md`). Desktop rows as of 2026-11-03, from
`docs/porting/status/`.

| Feature | Mac | Linux | Omarchy | Windows |
|---|---|---|---|---|
| Tray/menu bar ring, 3-2-1, hold-to-stop | ✅ | 🟡 | 🟡 (Waybar / omarchy-shell) | 🟡 (CI VM ran ring tap → 3-2-1 → pill → stop through the demo hooks; tray menu and hold-to-stop not pressed) |
| Record display / window | ✅ | 🟡 portal (tests on Arch + Ubuntu; no portal session run) | 🟡 portal + Hyprland mapping | ✅ display (CI VM: WGC on Server 2025, 1024×768, 5 s take ffprobed) · 🟡 window |
| Own cursor log + clicks | ✅ | 🟡 evdev/X11 | 🟡 Hyprland IPC | ✅ (CI VM: GetCursorPos samples + WH_MOUSE_LL clicks from injected input) |
| Pause = clip (double-tap Shift) | ✅ | 🟡 | 🟡 | 🟡 |
| Home (cards, import, reveal, trash) | ✅ | 🟡 | 🟡 | 🟡 (Home opens; cards not clicked) |
| Editor preview (same frame as the export) | ✅ | 🟡 (WebGL2 in WebKitGTK: 0.06–0.82/255 vs the Mac's frames; Mac HEVC takes play) | 🟡 | ✅ (CI VM, WebView2: 0.04–0.76/255 vs the Mac's frames; an HEVC take plays via the H.264 proxy) |
| Auto-zoom + zoom editing | ✅ | 🟡 | 🟡 | ✅ (CI VM: auto-zoom from recorded clicks; Z, Delete, undo/redo, drag) |
| Clips: split, trim, move, add take, undo | ✅ | 🟡 (split/trim/move/undo clicked through in WebKitGTK; add take/footage wired, not clicked through) | 🟡 (as Linux) | ✅ split, trim, undo (CI VM) · 🟡 move, add take/footage |
| Backdrops (colours, 20 paintings, own image, blur) | ✅ | 🟡 | 🟡 | ✅ colours + paintings (CI VM) · 🟡 own image, blur |
| Cursor looks (5) + tints + ripples | ✅ | 🟡 (tag in Inter Bold) | 🟡 (tag in Inter Bold) | ✅ Dot look in preview + export (CI VM) · 🟡 the rest (tag in Inter Bold) |
| Hide (blur/pixelate/cover) & crop | ✅ | 🟡 | 🟡 | ✅ (CI VM: hide box drawn and in the export; crop corner dragged) |
| Camera: over video, just me, with screen | ✅ | 🟡 (no live camera yet) | 🟡 (no live camera yet) | 🟡 (no live camera yet) |
| Music browser + ducking | 🚧 WIP | 🟡 (seen running in WebKitGTK; preview audio via media_url) | 🟡 | 🟡 |
| Export MP4 | ✅ | 🟡 (matches the Mac's export, run on macOS; in-app export run in the Arch container) | 🟡 | ✅ (CI VM: Ctrl+E in the editor → H.264 1080p, ffprobed) |
| Install | Homebrew | 🟡 AppImage/deb (config) | 🟡 PKGBUILD (srcinfo ok) + install.sh (tested on real 3.8.4 / 4.x configs) | 🟡 NSIS + ffmpeg sidecar (built in CI; the run uses the bare exes, not the installer) |
