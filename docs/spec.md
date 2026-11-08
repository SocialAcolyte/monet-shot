# Monet Shot: spec

**Job.** Record the screen and turn it into a polished demo video, with
zooms decided after recording.

**Interface.** A menu bar item (idle ring; countdown pill; clay ring + time +
hold-to-stop while recording) and a right-click menu. One editor window per
recording (preview, transport, inspector, timeline).

**Changes to the Mac, and how each is undone.** Creates `~/Movies/MonetShot/*.reel`
and `*.mp4` files (delete them to undo) and a log file. Nothing is changed in
system settings; no journal entries are needed.

**Failure behaviour.** Picker cancelled: back to idle. Capture fails to
start: the empty folder is removed, "Couldn't record" shows in the bar for a
few seconds, details in the log. Export fails: the editor says so, the edit
is kept.

**Camera.** Recorded in the editor over the playing edit (stored as
`cameraClips` in output time) or alone (a new take), or alongside a screen
recording (`camera.mov` in the take folder, `cameraOffset` in its meta, so
it follows the take's clips). Camera or microphone access denied: the
editor says so and offers System Settings; nothing is recorded. If the
camera fails to start with a screen recording, the screen still records.

**Pace and words.** Each clip has a `speed` (¼× to 4×; take seconds per
output second, so a 2× clip lasts half as long and its own camera sound
keeps its pitch) and `fadeIn`/`fadeOut` (output seconds: the finished frame
dissolves into the backdrop). Texts (`texts` in edit.json: title, caption
or label, in output time, centred on the canvas) come in by fade, rise,
pop or word by word, in Inter Bold (`Resources/Fonts`) on every platform.
A format (`format`: clean, fast, melancholic, cinematic) writes a pace and
a look into the edit in one go; nothing it sets is locked. These keys are
written only when used, so older edits are unchanged byte for byte.

**Music.** The app ships its own library in `Resources/Music` (one copy,
bundled by the Mac app and by Tauri): CC0 and public-domain tracks only,
levelled to -16 LUFS, AAC 96 kbps, each listed in `library.json` with its
licence, source page, moods, tempo (calm / steady / upbeat), energy, a
64-bar waveform and its beat grid (`grid`: bar, first downbeat, lifts).
`music` in edit.json is the chosen track (copied into the recording, so
exports work offline), `offset` (seconds into the song at the video's first
frame), `volume`, `fadeIn`, `fadeOut`. A chosen track starts on a downbeat
(`MusicFit.place`), and its end fade starts on a phrase line, every four
bars (`MusicFit.outro`, worked out from the track's grid each time the edit
renders, so a trimmed video still ends on a phrase). With "Lower music
while you talk" on, the music dips to 30 % wherever the edit's own sound
(the camera's mic, a voiceover) is above the take's quiet by its level
alone (`VoiceActivity`). A file of your own gets its grid read once and kept
with the choice. Favourites are this computer's own (UserDefaults on the
Mac, the webview's storage on Windows and Linux), not part of a recording.

**Non-goals.** System audio, keystroke overlays, multi-display takes,
cloud upload.
