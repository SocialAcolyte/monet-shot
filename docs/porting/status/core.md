# ms-core status

Owns `desktop/Cargo.toml`, `desktop/crates/{core,core-wasm,export}`, `shared/`.

## Done
- **1. Workspace + core model.** `monetshot-core` (`desktop/crates/core`):
  serde types for meta/cursor/edit.json with the Mac's keys, required keys and
  defaults; unknown keys kept (`extra`) and unknown enum values kept
  (`Other`); Swift-identical writer (`json::to_swift_json`: sorted keys,
  `"k" : v`, Swift number format, `\/`, empty `[\n\n  ]`); whole-second ISO
  dates. Project/Take load+save (atomic), `new_folder` (local time, " 2"
  suffixes), `next_take_folder`, `paths` per OS (MONETSHOT_HOME override).
  Verified: all 31 json files in 10 real recordings in ~/Movies/MonetShot
  re-encode **byte for byte** (`cargo test -p monetshot-core --test real_recordings`).
- **2. Contract.** `docs/porting/contracts/frame-plan.md`; code in `core/src/plan.rs`.

- **3. Fixtures.** `shared/tools/fixtures.sh` compiles `Sources/MonetShotKit/**`
  + `shared/tools/fixtures/main.swift` with swiftc (no Package change) and
  writes `shared/fixtures/*.json` (timemap, kept_clips, canvas, clip_edits,
  smooth, camera, auto_zooms, segment_edits, ripples, normrect,
  camera_clips, music_envelope, music, json, layout, cursor_art) and
  `shared/fixtures/render/` (10 Swift-rendered reference frames + sources,
  cursor art PNGs). `shared/LAST_SYNC` = HEAD + the uncommitted Kit files.
- **4. Port to green.** `cargo test -p monetshot-core`: 15 fixture suites
  match the Swift (1e-9), 18 MonetShotChecks ported (`tests/checks.rs`),
  real-recording round trip. Renderer pixel checks + cursor art go with export.
- **5. core-wasm.** `desktop/crates/core-wasm/build.sh` -> `pkg/` (web ES
  module). `Editor` (plan, timeline, framing helpers) + pure edits. wasm
  plan == native plan on a real recording. API sent to ms-app.

- **6. export** (`desktop/crates/export`, `monetshot-export`):
  - `cursor_art` (tiny-skia port of CursorArt.swift; also `cursorArt` in
    core-wasm): all 5 styles x 6 tints match the Mac's art, same sizes and
    hotspots, mean diff < 1.6/255. Name tag uses bundled Inter Bold (OFL,
    `assets/`), slightly lighter than SF Bold.
  - `Painter` (linear light like CoreImage; Lanczos for big shrinks, gamma
    bilinear otherwise; cached backdrop+shadow): the 10 Swift reference
    frames match at mean 0.04–0.8/255 (`--test render`).
  - Pipeline: ffmpeg decode (prefetch thread per file) -> paint -> encode
    (writer thread; hw encoder probed: videotoolbox / nvenc / qsv / amf /
    vaapi, else libx264/libx265; HEVC above 3000 px as the Mac), BT.709
    tags, 60 fps, AVFoundation's frame count. Audio mixed in Rust at 44.1
    kHz: camera clips + take cameras placed as Composer.addCamera, music
    looped from its offset with the Mac's 0.1 s ramps and ducking. Credits
    file for CC BY. Progress + cancel (no partial file left).
  - `render_still`, `thumb_time`, `write_thumb` (thumb.jpg as the Mac's
    Home), `thumb_is_fresh`; `imports::{new_project_from_video, video,
    recording}`; `sound::{waveform, grid}`; `probe`.
  - Verified on this Mac: exported real recording `2026-11-01 20.38.33`
    and compared with the Mac's own export of it: same 432 frames, timing
    aligned (PSNR Y 34 dB; ±1 frame drops to 20), music RMS within 0.001
    per 0.25 s. Camera-clip recording `20.06.23`: bubble fades/grows as on
    the Mac. 4K export ≈ 20 fps (10.6 s in 31 s). `--test pipeline` runs
    import -> add take -> camera + music -> export -> thumb on generated media.

## Checks
- `cargo test -p monetshot-core -p monetshot-export` (41 tests) green on macOS.
- `cargo check` for x86_64-unknown-linux-gnu and (cargo-xwin)
  x86_64-pc-windows-msvc: clean. NOT run: anything on Windows, and no hw
  encoder other than macOS videotoolbox.
- Linux (ms-capture, Arch container, 2026-11-02): the export ran end to
  end (HEVC source, painting backdrop, crop, hide, cursor all correct).
  The WebGL preview on WebKitGTK + llvmpipe matches the Mac's reference
  frames at mean 0.06–0.82/255, the same as WKWebView on the Mac
  (0.03–0.76). Still container, not Linux hardware or hw encoders.
- `MONETSHOT_PROFILE=1` prints the painter's per-stage timings.

## Open
- Music grid on real songs is only checked for "finds a beat" (decoders
  differ from AVFoundation's slightly); synthetic songs match the Mac exactly.
- Grain is a fixed hash noise, not CIRandomGenerator's.

## Notes
- Music on the Mac is mid-edit (Music.swift, MusicGrid.swift uncommitted):
  ported as in the working tree on 2026-11-01.
