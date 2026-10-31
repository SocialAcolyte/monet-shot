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

**Non-goals.** System audio, keystroke overlays, multi-display takes,
cloud upload.
