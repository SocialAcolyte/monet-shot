# You are ms-core: the brain and the export

Read `docs/porting/ARCHITECTURE.md` and `docs/PARITY.md` first. You own
`desktop/Cargo.toml`, `desktop/crates/{core,core-wasm,export}` and `shared/`.

Port the Mac's logic so Linux/Windows behave **identically**. Source of
truth: `Sources/MonetShotKit/**` (read the working tree; Music is mid-edit by
Connor, port what's there and note it) and `Sources/MonetShotChecks/main.swift`.

## Order

1. **Workspace + core model.** `desktop/Cargo.toml` (members `crates/*`).
   `crates/core`: serde types for every `.reel` file, matching the Swift JSON
   exactly (key names, sorted keys, pretty print, whole-second ISO dates,
   tolerant defaults, keep unknown keys on round-trip). Load/save Project and
   takes, `newFolder` naming, Paths per OS (see ARCHITECTURE). Load Connor's
   real recordings in `~/Movies/MonetShot/*.reel` read-only as a smoke test.
2. **Contract.** Write `docs/porting/contracts/frame-plan.md` (FramePlan
   types in Rust + TS shape) EARLY and message `ms-app` when it's there; they
   build the WebGL preview painter against it. Read `Render/Renderer.swift`,
   `Composer.swift`, `Compositor.swift`, `CursorArt.swift` to get it right.
   Coordinates top-left origin.
3. **Fixtures.** `shared/tools/fixtures/main.swift` + a script that compiles
   `Sources/MonetShotKit/**/*.swift` with it via swiftc (no Package.swift
   change) and writes `shared/fixtures/*.json`. Cover: TimeMap, ClipEdits,
   keptClips, canvasSize, SmoothTrack, camera(at:), autoZooms, reAuto,
   SegmentEdits, ripples, pressScale, NormRect ops, CameraEdits, presence,
   MusicEnvelope, frame layout per take. Also render a few reference frames
   with the Swift Renderer into `shared/fixtures/render/` (PNG + the doc used).
   Write `shared/LAST_SYNC` with the current HEAD.
4. **Port the math** until `cargo test` matches every fixture. Port
   MonetShotChecks' assertions too.
5. **core-wasm**: wasm-bindgen exports for the UI (open project JSON, plan
   at t, timeline helpers, edits). Build with `wasm-pack` or
   `wasm-bindgen-cli`; give `ms-app` the exact build command.
6. **export**: tiny-skia painter for FramePlan (rounded clip, cached shadow,
   backdrop + cached blur, region blur/pixelate/cover, cursor art for all 5
   styles x tints + label pill, ripples, camera bubble circle/rounded,
   mirroring). Compare against `shared/fixtures/render/` with a tolerance.
   Pipeline: ffmpeg decode per take (rawvideo pipe, seek by clip) -> paint ->
   ffmpeg encode (pick hw encoder, fall back to libx264), audio: take audio,
   camera voice, music with the Mac's envelope/ducking. Progress callback +
   cancel. Import: ffprobe a video into a take (`source: "import"`).
   Export a real `.reel` from `~/Movies/MonetShot` end to end on this Mac and
   look at frames from it.

Keep `docs/porting/status/core.md` current. Don't commit. Tell the lead
(`stylefeatures-d1`) when each numbered step is done.
