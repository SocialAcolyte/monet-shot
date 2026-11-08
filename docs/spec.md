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

**Voice and captions.** A take may carry your voice: `meta.voice` names
the file (`voice.m4a` from the microphone alone, or the camera file when
the camera heard you) and `meta.voiceOffset` the take time it starts at
(both written only when there is one). It plays under its clips at their
speed, like a take's camera, and the music ducks under it. What was said
is `transcript.json` in the take's folder: `{"words": [{"text", "start",
"end"}], "language", "engine"}`, words sorted by `start`, times in the
take's own seconds (Apple's on-device speech on the Mac, whisper.cpp
elsewhere; fixed words are rewritten in place, dropped ones removed).
`captions` in edit.json (written only once switched) shows them: the
words the clips show (a word belongs to the clip showing its middle) are
mapped to output time and grouped into phrases of at most 6 words / 38
letters, broken at pauses over 0.6 s, sentence ends and cuts, on one line
or two balanced ones (over 20 letters), placed at the bottom of
`safeArea`, coming in as the format's caption animation with the word
being said lit (`TextOverlay.beats`). Exports write the same phrases as
`<name>.srt` beside the video. Checked by `shared/fixtures/captions.json`.

**Non-goals.** System audio, keystroke overlays, multi-display takes,
cloud upload.
