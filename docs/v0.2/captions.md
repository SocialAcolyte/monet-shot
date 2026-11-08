# You are ms-captions: transcription and captions

Branch `feat/captions`, worktree `~/Developer/monetshot-wt/captions`. Read
`docs/v0.2/README.md` first.

## The problem
Monet Shot records voice only through the camera (CameraRecorder: the mic is
captured with the webcam; the screen itself records no audio). There is no
transcription. Text overlays exist (`Text.swift`, `text.rs`: title, caption,
label; fade, rise, pop, word by word) and are drawn identically on both sides.

## What to build (Mac and desktop)
1. **Voice without the camera.** A microphone choice where you start a
   recording (off / which mic), independent of the camera: records a
   voiceover track into the take (Mac: AVCaptureSession or AVAudioEngine;
   desktop: the capture crate's ffmpeg mic path). Shows in the timeline as a
   voice lane, plays in preview, mixes into the export (and is a ducking
   source for the music agent; agree nothing else with them). Camera + mic
   keeps working as before.
2. **Transcription, on device, free, private.**
   - Mac: Apple's on-device speech (macOS 26 `SpeechAnalyzer` /
     `SpeechTranscriber`; fall back to `SFSpeechRecognizer` with
     `requiresOnDeviceRecognition` if needed). Mind permissions with an
     ad-hoc signed app (Info.plist usage strings; test it really runs from
     `~/Applications/Monet Shot.app`, not only from `swift run`).
   - Windows/Linux: whisper.cpp via `whisper-rs` (or the whisper.cpp CLI as a
     sidecar if building it in CI is easier), with a small model
     (base / base.en, or a quantised small) **downloaded on first use** with
     progress, cached in the app data dir, checksum-verified. Not bundled.
   - Word-level timestamps, in source time of the take, saved in the take as
     `transcript.json` (one shared format; document it in spec.md and add a
     fixture). Mapped through the edit's TimeMap (cuts, speed) to output time.
   - Runs automatically after a recording with a voice (setting, on by
     default), or from a "Transcribe" button; progress shown, cancellable.
     Language: auto or chosen.
3. **Captions.** One switch, "Captions", turns the transcript into styled
   captions over the video: short phrases (≤ ~6 words / 2 lines), word by
   word highlight, in the format's text style, placed in the safe area
   (bottom third; in a vertical canvas use `safeArea(canvasWidth,
   canvasHeight)` from the vertical agent: if it isn't on your branch, add a
   minimal one with exactly that signature in both Kits returning the whole
   canvas inset by 6%, and the lead will reconcile). Click a word in a
   transcript panel to fix a typo or delete a filler; edits persist.
   Optional and only if it's clean: "cut the silences / filler words" as a
   one-click suggestion that writes cuts.
4. **Subtitles out.** Every export also writes `<name>.srt` beside the video
   when there's a transcript (setting), and a "Copy transcript" action.

## Parity and proof
- The phrase-grouping and timing logic (transcript → caption overlays) is
  pure and shared: Swift golden fixtures (`shared/fixtures/captions*.json`,
  a reference frame) checked by Rust tests; MonetShotChecks cases.
- Prove transcription for real on both sides with a real voice: synthesise a
  test sentence (`say -o` on the Mac to an aiff/m4a), run it through the Mac
  transcriber, and through whisper in CI on Linux and on the Windows VM
  (windows-run: download the model, transcribe, export a captioned frame,
  upload it). Word error rate on the test sentence should be ~0.
- Look at the captioned frames yourself. UI snapshots of the transcript
  panel and the captions switch on both sides. PARITY rows, README, spec.

## Shared seams
You own the voiceover track, transcript, captions, .srt. You add a voice
lane to the timeline and a mic choice to the recording UI; keep those
changes small. Don't change canvas/framing (vertical agent) or music
(music agent).
