# You are ms-music: better music selection

Branch `feat/music`, worktree `~/Developer/monetshot-wt/music`. Read
`docs/v0.2/README.md` first.

## Where it stands
- The Mac app used Kevin MacLeod's incompetech catalogue, fetched online
  (Connor called the Openverse music trash before that, and wants better than
  MacLeod).
- Connor's own work in progress, now committed on `v0.2` as `cb43f95`:
  a **bundled** library of 20 CC0 / public-domain tracks in
  `Resources/Music` + `library.json`, levelled to one loudness, moods
  dreamy / grooving / sunny / mellow / impressionist, a `MusicGrid`. It was
  never finished or checked: make sure it builds and works first.
- His listening notes and candidates: `~/Developer/monetshot-music`
  (`candidates.json`, `listen.html`, `keep/README.md`, `slap/` + `slap.json`
  = 16 punchier candidates he gathered after, `tools/`). Read them; they say
  what he liked.
- The desktop app (`desktop/crates/core/src/music.rs`,
  `desktop/crates/export/src/sound.rs`, `desktop/app/ui/src/editor/music/`)
  still uses incompetech.

## What to build
1. **A library worth choosing from.** About 40-60 tracks, all CC0 or public
   domain (no attribution strings to carry, nothing NC/ND/SA), that suit
   product demos and screen recordings: warm, modern, well produced, real
   instruments or good production, nothing cheesy, no stock-corporate
   ukulele. Cover a spread of moods and tempos, and include the "slap"
   set's energy for vertical/short videos. Sources: Free Music Archive CC0
   artists (HoliznaCC0, John Bartmann, Loyalty Freak, Zane Little,
   Tequila Moonrise...), Musopen / public-domain classical recordings that
   are themselves CC0/PD, Pixabay is NOT CC0 (its own licence): avoid.
   Verify each licence on its source page and record it in library.json.
   **Use the `earshot` skill/MCP to judge** every candidate (rank, describe,
   realness) since you can't hear: keep only ones that score as real,
   well-produced music; level them with the existing tools; store the
   reasoning in `docs/v0.2/status/music-picks.md`.
   Size: keep the installed library under ~80 MB (AAC ~96-128 kbps, trim
   long tracks to their best 2-3 minutes at a phrase boundary).
   Ship the same files to the desktop app (Tauri `bundle.resources`, one
   copy of the files in the repo: `Resources/Music`, like
   `Resources/Backdrops` is shared, see PARITY §3).
2. **A browser that helps you choose.** In both editors: mood chips, tempo
   (calm / steady / upbeat), a waveform per track, click to hear it *under
   your own video* (preview plays the edit with that track), a short list of
   suggestions ranked for this video (length, the format's mood, vertical =
   punchier), and favourites remembered. Keep "a file of your own".
3. **Music that fits the edit.** The track starts at a good point and ends on
   a phrase with a fade at the video's end (not chopped mid-bar), and it
   **ducks under speech** when the take has a voice (mic audio with the
   camera, or the voiceover the captions agent adds: duck on the audio level
   of any voice track, so you don't depend on their transcript). Same
   envelope math in both Kits, with fixtures (`music_envelope.json` exists;
   extend it).

## Parity and proof
Fixtures from Swift for the library parsing, suggestions ranking and the
envelope; MonetShotChecks; Rust tests; CI green on all jobs; a real export
with music on the Mac and on the Windows VM (windows-run), and measure the
result with earshot (loudness, the duck actually dipping under voice). UI
snapshots of both browsers. PARITY rows, README (credits section: list the
artists even though CC0 doesn't require it), spec.

## Shared seams
You own `Resources/Music`, music.rs/sound.rs, the music browsers and the
envelope. The captions agent may add a voiceover (mic-only) audio file to a
take; treat any take audio as a ducking source.
