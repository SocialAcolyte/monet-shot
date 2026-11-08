# ms-captions status: voice, transcription, captions, subtitles

Branch `feat/captions`. Mac app and desktop (Windows/Linux) alike.

## What was built

**Shared format** (both Kits, `docs/spec.md` "Voice and captions"):
- `meta.voice` / `meta.voiceOffset`: the file holding your voice (`voice.m4a`
  from the microphone alone, or the camera file when the camera heard you)
  and the take time it starts at. Written only when there is one.
- `transcript.json` in each take folder: words `{text, start, end}` in the
  take's own time, sorted, plus `language` and `engine` (`apple` / `whisper`).
- `edit.captions` (written only once switched) shows the captions.
- `TextOverlay.beats` (spoken timing) and `TextState.highlight` (the word
  being said, lit in the tone's highlight: clay, or light on clay).
- `Captions` (Swift) / `captions.rs` (Rust): words mapped through the
  TimeMap (cuts, order, speed); phrases of at most 6 words / 38 letters,
  broken at pauses over 0.6 s, sentence ends and cuts; one line or two
  balanced lines; anchored to the bottom of `safeArea` (a stub: the whole
  canvas inset by 6%, `Sources/MonetShotKit/Model/SafeArea.swift`,
  `desktop/crates/core/src/safe_area.rs`; the vertical branch owns the real
  one); 1.25× size on a tall canvas; the format's caption animation
  (Clean/Fast: word by word, each word arriving as it is said; Melancholic,
  Cinematic: fade). SRT and plain text from the same phrases.
- Fixtures: `shared/fixtures/captions.json` (24 random cases through cuts
  and speeds on four canvases: words, phrases, SRT, text, states with the
  lit word; line breaking, transcript edits, meta and edit round trips,
  safe area) and reference frames `render/charcoal-captions.png`,
  `render/dusk-captions-tall.png`. All older fixtures are byte-identical.
  `shared/fixtures/voice/sentence.m4a` (+ `.txt`): the test sentence,
  spoken by `say` on the Mac.

**Mac** (`Sources/MonetShot`):
- Status menu: *Microphone* submenu (Off + each input) under *Record My
  Camera Too*. `VoiceRecorder` (AVCaptureSession + AVCaptureAudioFileOutput)
  writes `voice.m4a` beside the screen; the camera uses the chosen mic.
- `Render/Voice.swift`: the voice under its clips at their speed (own
  audio track), music ducks under it.
- `Speech/Transcriber.swift`: SpeechAnalyzer/SpeechTranscriber with word
  times (falls back to on-device SFSpeechRecognizer); progress, cancel;
  language Automatic or chosen; runs when a take with a voice and no
  transcript opens (setting).
- Inspector *Captions* section, transcript panel (click a word to fix or
  empty it), *Copy transcript*, two settings; a voice lane with word ticks
  in the gap under the clips. Exports write `<name>.srt`.
- CLI: `--transcribe <reel> [lang]`, `--captions <reel> on|off`.
- UserDefaults: `micDevice`, `transcribeLanguage`, `autoTranscribe`,
  `writeSubtitles`. Info.plist: speech and microphone usage strings.

**Desktop** (`desktop/`):
- capture: `voice.rs`: the microphone alone (ffmpeg pulse / dshow) into
  `voice.m4a`; the file's start is its first sound; meta written as on the
  Mac. Tray: *Microphone* submenu. Settings in `support/speech.json`.
- `crates/transcribe` (new): whisper.cpp via whisper-rs 0.16, the
  multilingual `ggml-base-q5_1.bin` (57 MB) downloaded on first use with
  curl, progress, SHA-256 checked, kept in the local data dir
  (`MONETSHOT_HOME/models` in tests); one word per segment; cancellable
  (own abort trampoline: whisper-rs's safe one aborts at random).
  `.cargo/config.toml` sets `GGML_NATIVE=OFF` so builds don't target the
  build machine's CPU.
- export: the voice mixed under its clips (and ducking the music);
  `subtitles.rs` writes `<name>.srt`. Preview: an `<audio>` per voiced take
  follows the clip on screen.
- editor: `CaptionsSection.svelte`, `speech.svelte.ts`, the voice lane in
  `Timeline.svelte`; core-wasm takes each take's transcript, gives caption
  words, transcript text and SRT, and re-plans on a fix.
- Also fixed on the way (Windows): `media.rs` resolved `file:///D:/…`
  song URLs to `/D:/…`, failing `shapes_a_library_song` (music's code, from
  main); the media server test now keeps a reset response.

## How it was proven

- **Mac (this Mac, macOS 27.0.1)**: the app built with
  `scripts/build-app.sh` into `scratch/` (not installed), ad-hoc signed,
  ran `--transcribe` on a take whose voice is the test sentence (offset
  0.5 s): SpeechAnalyzer, en_AU, 0.6 s, no permission prompt. WER 1/16
  ("polish" for "polished"). Export with captions: H.264 + AAC (the voice),
  and `<name>.srt` with 3 phrases (`captions/mac-voice-test.srt`). Frames
  looked at (`captions/mac-captioned-frame.png`); the Captions section
  snapshot (`captions/mac-captions-section.png`). Opening the editor
  transcribed automatically. MonetShotChecks: 145 pass (captions through a
  cut and a 2× clip, SRT, lit word, renderer on/off, voice track placement
  at 1× and 2× on a real AVAssetWriter take).
- **CI macOS**: swift build, MonetShotChecks, fixtures fresh.
- **CI Ubuntu / Windows** (`crates/transcribe/tests/sentence.rs`, real
  whisper): see "CI" below.
- **CI Windows VM** (`windows-run` stage 9, `devchecks/captions.js`): see "CI".

## CI

(filled in below when green)

## Not proven

- A real microphone recording on any platform (needs a mic and its
  permission; the Windows VM has none). The Microphone menus were not
  opened. The camera + mic path setting `meta.voice` is untested.
- On the Mac: the word-fix popover (an offscreen snapshot can't open it;
  its logic is checked), and running from `~/Applications` (deliberately
  not installed).
- Linux/Omarchy UI: the Captions section and transcript panel ran only in
  WebView2 (Windows VM); WebKitGTK not driven.
- Clips of you recorded over the edit in the editor are not transcribed.
- "Cut the silences / filler words" was not built (optional in the brief).

## Merge notes

- Likely conflicts: `Project.swift` / `model.rs` (new meta and edit
  fields), `Text.swift` / `text.rs` (beats, highlight), `Renderer.swift` /
  `plan.rs` (captions drawn after the texts; `Planner.captions`,
  `with_transcripts`), `InspectorView.swift` (made `Section`, `Hint`,
  `ToggleRow`, `ChipStyle` non-private; one `CaptionsSection` line),
  `Inspector.svelte` (one line), `Timeline.svelte` / `MonetShotTimeline`
  (voice lane), `StatusItemController.swift` and `tray.rs` (Microphone
  submenu: the vertical branch adds its option there too), `Composer.swift`
  and `export.rs` (two lines each for the voice; music edits those too),
  `shared/tools/fixtures/main.swift`, `shared/fixtures/render/cases.json`
  (two appended cases), `docs/PARITY.md`, `README.md`, `docs/spec.md`,
  `.github/workflows/desktop.yml`.
- `safeArea`: replace the stubs with the vertical branch's; captions use
  `safeArea(canvasWidth:canvasHeight:)` (top-left origin rect) and
  `safe_area(w, h)`; regenerate fixtures after (`captions.json` and the
  two caption frames will change if the area does).
- `Cargo.lock` was not updated locally (no local cargo): the first local
  build or `cargo update -p monetshot-transcribe` adds whisper-rs, sha2.
- New build dependency: cmake (CI, PKGBUILD makedepends, Dockerfiles).
