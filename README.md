# Monet Shot

A Screen Studio–style recorder that lives in the menu bar. Record a display
or a window, then zoom in on what matters after the fact: Monet Shot logs every
pointer move and click while it records, zooms on your clicks automatically,
draws its own smooth cursor, and frames the result on a backdrop. Blur or
crop away anything private before you share it. The look follows
[Insomnia](https://github.com/krishhgg/Insomnia).

## Use it

- **Record.** Click the ring in the menu bar and pick a display or window in
  macOS's own picker. A 3‑2‑1 rolls in the bar, then the ring turns clay and
  the time ticks. **Press and hold** the small square to stop (a stray click
  can't end a take). Click during the countdown to cancel.
- **Clips.** **Double-tap Shift** (or click the pause button in the bar) to
  pause; do it again to resume. Paused stretches are cut out of the video, so
  each take plays straight into the next. They show hatched on the timeline;
  select one and press Delete (or Restore) to put it back.
- **Home.** Launching Monet Shot (or *Open Monet Shot* in the ring's right-click
  menu, ⌘O) shows your recordings as cards, rendered with their backdrop.
  Click one to edit it; *Import video* turns any video file into a Monet Shot
  edit; right-click a card to show it in Finder or move it to the Trash.
- **Edit.** The editor opens by itself after a recording. Auto-zooms are already on the
  timeline, one per cluster of clicks.
  - Drag a zoom to move it; drag its ends to resize; double-click empty track
    (or press **Z**) to add one; **Delete** removes the selected one.
  - Inspector: zoom depth, *Follow cursor* or *Hold still* (then click the
    preview to choose where it looks), backdrop (four colours, none, or a
    **picture**: pick one, or drop it on the preview; it is copied into the
    recording, with optional blur), padding, corners, shadow,
    cursor size and smoothing, click ripples, output size and aspect.
  - **Clips.** The timeline is the finished video: its clips end to end,
    each a filmstrip of its own footage with a handle at each end. Drag a
    handle to shorten or lengthen the clip; drag a clip's middle to move it
    elsewhere in the order; **S** (or Split) cuts the clip under the
    playhead in two; **Delete** removes the selected clip. **⌘Z** / **⇧⌘Z**
    undo and redo anything.
  - **Add clip.** *Record a new take* (the editor steps aside, you record,
    and the take lands at the end with its own auto zooms), or *Add a video
    or recording…* (any video file, or another Monet Shot recording with its
    zooms). You can also drop videos onto the timeline. Takes can be
    different sizes; each is framed at its own shape. Zooms belong to the
    footage they were made on and travel with it.
  - **Speed.** Select a clip: *Speed* plays it from ¼× to 4× (chips for
    0.5×, 1×, 1.5×, 2×, 4×; *All clips* sets every clip). The timeline
    shows each clip at its played length with a speed badge; zooms, the
    cursor and hides stay on their footage. *Fade in* / *Fade out* dissolve
    the clip from and into the backdrop.
  - **Text.** *Title*, *Caption* or *Label* (or **T** for a title) puts
    words at the playhead, on their own lane: drag to move, drag an end to
    retime. Each comes in by *Fade*, *Rise*, *Pop* or *Word by word*, in
    light, dark or clay, at the top, middle or bottom, with an optional box.
  - **Format.** *Clean*, *Fast pace* (1.5×, hard cuts, deep zooms, words
    that pop), *Melancholic* (0.85×, every clip fading through dusk, soft
    zooms) or *Cinematic* (long fades in and out, titles in capitals) sets
    the pace and look in one go, and suggests a music mood. Everything
    stays adjustable; ⌘Z undoes it.
  - **Shape.** *Landscape*, *Vertical* (1080×1920, for Reels, Shorts and
    TikTok) or *Square* (1080×1080), at the top of the inspector. Vertical
    doesn't shrink the screen into a strip: the recording fills the phone
    frame at its full height and the frame follows the action like a
    camera operator, holding still while you work in one place and gliding
    to wherever you click or zoom next. Texts stay clear of the phone apps'
    buttons (the dashed line in the preview), and the camera bubble sits
    larger, in the lower third. *Landscape* brings the landscape edit back
    as it was. **Record Vertical** in the ring's right-click menu (or the
    shape toggle on Home) makes every new recording open vertical.
  - **Space** plays,
    **←/→** step a frame (with Shift, a second), **A** re-runs auto-zoom.
- **Hide & crop.** *Hide* (or **B**) shows the take whole, so you can
  take out what shouldn't be seen, like a chat, an inbox or a token in a
  terminal:
  - *Hide*: drag a box over it. Each box is **Blur**, **Pixelate** or
    **Cover** (solid), with a strength. It is drawn into the raw frame,
    so it stays over its content through every zoom. A box hides its
    part for the whole take; move the playhead and press *Start here* /
    *End here* to hide it for only part of the take.
  - *Crop*: drag the edges to keep only part of the screen, for example
    the browser without the chat beside it. The kept part is framed as if
    it were the whole recording; the cursor, clicks and zooms follow.
  - Boxes move by their middle and resize by their handles; **Delete**
    removes the selected one; **R** switches between Hide and Crop; **Esc**
    or *Done* goes back to the finished look.
- **Cursor.** Five looks in the inspector: *Classic*, *White*, *Soft* (a
  rounded arrow in a colour), *Dot* (a soft bubble, like a touch demo) and
  *Name tag* (an arrow with your name in a pill). The tinted ones come in
  six colours, and their click ripples match.
- **You on camera.** *Camera* (or **C**) brings out the webcam:
  - *Over the video*: press Space (or Record), 3‑2‑1, and the edit plays
    from the playhead, muted, while you talk over it. You land in a bubble,
    exactly where the preview shows you. Record again over a stretch to
    replace it.
  - *Just me*: a clip of only you, added at the end and framed like the rest.
  - Camera clips sit on their own lane under the zooms; right-click one to
    have it **fill the frame** instead of the bubble, or delete it. The
    inspector sets circle or rounded, corner, size and mirroring, and ducks
    the music while you talk.
  - **While recording the screen:** tick *Record My Camera Too* in the
    ring's right-click menu. You see yourself in a bubble during the 3‑2‑1;
    it hides when recording starts (it would be in the capture) and the
    camera keeps recording alongside, following the take's clips and cuts.
- **Your voice and captions.** Pick a *Microphone* in the ring's
  right-click menu (Windows/Linux: the tray menu) and your voice records
  beside the screen, without the camera. It shows as a thin lane under the
  clips, plays in the preview, goes into the export, and the music ducks
  under it. With the camera on, the camera's microphone is your voice.
  - When a take with a voice opens, it is transcribed on this computer:
    Apple's on-device speech on the Mac; on Windows and Linux whisper.cpp,
    whose small model (57 MB) downloads once, with progress, the first time.
    Nothing is uploaded. *Transcribe* runs it again (any language, or
    *Automatic*), with progress and a way to stop.
  - *Captions* puts what you said over the video in short phrases at the
    bottom, the word being said lit in clay, in the format's way of bringing
    words in. Click a word in the transcript to fix it, or empty it to drop
    a filler. *Copy transcript* copies the text.
  - Every export also writes `<name>.srt` (subtitles) beside the video.
- **Music.** *Music* (or **M**) opens the browser beside your video: 43
  tracks that come with the app, all CC0 or public domain, so there is
  nothing to credit and no conditions. *For this video* suggests a few that
  suit its length and format (punchier ones for a vertical video); or pick a
  mood (Dreamy, Grooving, Sunny, Mellow, Punchy, Classical) and a tempo
  (Calm, Steady, Upbeat), or search. Click a track and it plays **under your
  own video**, from where it would start; the waveform lights the part you
  hear. The heart keeps a track in *Favourites*. *Use* puts it in the edit,
  starting on a downbeat and fading out from a phrase line so it ends with
  the video instead of mid-bar. *Your own* takes a file you've licensed
  elsewhere. In the inspector, slide the bright window along the waveform to
  choose which part plays (it snaps to bar lines), and set volume and fades.
  With "Lower music while you talk" on, the music dips wherever your voice is
  heard (the camera's mic, a voiceover), by its level alone.
- **Export.** *Export MP4* (⌘E) renders the edit next to the recording at up
  to 4K, 60 fps.

Right-click the ring for recent recordings, *Open Recording…*, and the folder.

## Install

With [Homebrew](https://brew.sh) (macOS 26, Apple Silicon):

```sh
brew tap socialacolyte/tap
brew trust socialacolyte/tap
brew install --cask monet-shot
```

Or download the zip from [Releases](https://github.com/SocialAcolyte/monet-shot/releases). Monet Shot is not
notarised by Apple yet: the first time you open it, go to System Settings › Privacy & Security and
click **Open Anyway**.

From source:

```sh
scripts/install.sh            # builds, signs ad-hoc, installs to ~/Applications
open ~/Applications/Monet\ Shot.app
```

Command Line Tools are enough (no Xcode). `swift run MonetShotChecks` runs the
tests. From a script (the command is `MonetShot`, one word):

```sh
MonetShot --auto   <rec.reel>                 # (re)make auto zooms from the clicks
MonetShot --frame  <rec.reel> <s> <out.png>   # one finished frame
MonetShot --render <rec.reel> <out.mp4>       # the full export
MonetShot --add    <rec.reel> <video|rec.reel>…  # add footage as clips at the end
MonetShot --format <rec.reel> fast              # clean | fast | melancholic | cinematic
MonetShot --aspect <rec.reel> vertical          # landscape | vertical | square (--vertical <rec.reel> for short)
```

## What it changes on your Mac

- Writes recordings to `~/Movies/MonetShot/` (one `.reel` folder each: the raw
  video, the cursor log, and the edit) and exports beside them.
- A log at `~/Library/Logs/MonetShot/monetshot.log`.
- Your favourite tracks, in the app's preferences.
- Monet Shot doesn't talk to the network: the music comes with the app.
- Nothing else: no login item, no background service, no system settings.

**Permissions.** None for the screen. Camera and Microphone are asked
for the first time you record yourself (an ad-hoc signed build may ask
again after a rebuild). The system sharing picker gives Monet Shot access
to just the chosen display or window for that recording, which is also why
it keeps working after each rebuild of an ad-hoc signed app. Pointer
positions are polled and clicks come from a mouse event monitor; neither
needs Accessibility. Monet Shot records sound only from the microphone, only
while recording yourself or with a *Microphone* chosen, and never keystrokes.
Transcription runs on the Mac (Speech may download its on-device model for
your language once).

## How it works

- `MonetShotKit/Core/CameraMath.swift`: cursor smoothing (a critically damped
  spring run forwards and backwards, so the cursor glides without lagging
  behind your clicks), auto-zoom from click clusters, and the camera at any
  moment (smootherstep in and out, centre clamped inside the recording).
- `MonetShotKit/Render/Renderer.swift`: one CoreImage pass per frame: hidden
  boxes blurred into the raw frame, the crop, backdrop with grain, soft shadow, the recording zoomed and rounded, the vector
  cursor and click ripples. The editor's preview and the export run the same
  code, so what you see is what you get. `Compositor.swift` feeds it the
  screen frame and whichever camera frame is there (clips recorded in the
  editor win over a take's own camera).
- `MonetShot/Recording/`: `SCContentSharingPicker` + `SCStream` +
  `SCRecordingOutput` (HEVC, cursor hidden), and the 120 Hz cursor tracker.
- Pauses: ScreenCaptureKit can't pause a file, so Monet Shot keeps capturing and
  marks the stretch as a cut. `TimeMap` turns trim and cuts into the kept
  spans; the player and export run an `AVMutableComposition` of just those,
  and the renderer maps output time back to recording time for the cursor
  and zooms. Double-tap Shift is read from the modifier state, which needs no
  permission (key events would).
- When recording a display, the edit ends just before the pointer went up to
  the menu bar to stop.

## Known limits

- One display or window per take; a window is assumed not to move while
  recording. No system audio; your voice comes from the microphone or the
  camera. Clips of you recorded over the edit in the editor aren't
  transcribed (a take's own voice and camera are).
- Hidden boxes are fixed rectangles: they don't track something that
  moves or scrolls. Time them with *Start here* / *End here*, or crop it
  away.
- Requires macOS 26 and Swift 6.2 (the Command Line Tools are enough).

## Backdrop paintings

Monet Shot comes with 20 paintings for the picture backdrop (Monet, Van Gogh, Turner, Sargent, Homer, Hokusai, Klimt, Seurat, Cézanne, Sorolla). All are public domain or CC0 scans from Wikimedia Commons; each one's title, artist, licence and source page are in `Resources/Backdrops/credits.json`.

## Music

The tracks in `Resources/Music` are CC0 or public domain: free to use
anywhere, no credit needed. Each one's licence and source page are in
`Resources/Music/library.json`. Thank you to the people who gave them away:

- **HoliznaCC0**: Lost On The Freeway, Night Driving, Night Life, Day Trips,
  Sky Scrapers, Make Love, Dancing, Moving Forward, Back In The 80s, The Last
  Long Day, Roof Tops, Hope On Repeat, Spring In Sight, Spring On The
  Horizon
- **John Bartmann**: Lofi Jam, Disco in the Sky, Born to Boogie, Party Party
  Disco Party, Rich Mahogany, Autotune Will Not Save You, Rusty Bicycle,
  Guessing Game, Winter Rain, Grassroots Programming, Self-Driving Nights,
  Spirit Of Java, Back To Basics
- **Loyalty Freak Music**: Summer Pride, Monarch of the Street, People Are
  Spinning, Chillin With a Drink at the Club, Lag, No Cadillac
- **Zane Little**: Rhythm Factory, Goober Dynamics 1
- **Tequila Moonrise**: Don't Ride the Dolphin
- **Kimiko Ishizaka** (Open Goldberg Variations, Open Well-Tempered
  Clavier): Bach, Aria; Prelude in C major
- **Musopen** and **Luke Faulkner**: Chopin, Nocturnes Op. 9 No. 2 and
  Op. 15 No. 2
- **Robin Alciatore** (Musopen): Satie, Gymnopédie No. 1
- **The United States Marine Chamber Orchestra**: Debussy, Danse sacrée and
  Danse profane

## License

MIT, see [LICENSE](LICENSE). The music that comes with the app is CC0 or
public domain (above); music you bring is yours to license.
