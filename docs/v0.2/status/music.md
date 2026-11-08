# ms-music: better music selection (status)

Branch `feat/music`, merged with `v0.2` at 0.2.0 (`28bafb4`: vertical, captions, Connor's 20-track library),
so it can ship as 0.2.1. Brief: `docs/v0.2/music.md`.

## What was built

**A library worth choosing from.** 43 tracks in `Resources/Music` (76 MB), all CC0 1.0 or public domain,
each licence read on the track's own page and recorded in `library.json` (`license`, `licenseURL`,
`pageURL`). Moods: Dreamy 16, Mellow 16, Grooving 13, Punchy 9, Classical 9, Sunny 7 (a track can sit in
two). Tempo: calm 21, steady 11, upbeat 11. Connor's 20 were re-made from his originals (3 left out: two
vocal tracks with an AI question, one ukulele), his "slap" picks are in as Punchy, plus 19 new FMA tracks and
4 piano recordings (Kimiko Ishizaka's Bach, Musopen's Chopin). Every candidate (103 FMA + 6 Commons, plus
Connor's 46) was judged with earshot; the reasons, numbers and the ones left out are in
`docs/v0.2/status/music-picks.md`. Files: trimmed to end on a phrase line (or a breath, for piano), -16
LUFS, AAC 96 kbps. "Impressionist" became "Classical" (Bach and Chopin aren't impressionists).
`library.json` also carries what the browser and the fit need: `tempo`, `energy`, the beat `grid` read by
the Kit's own `MusicGrid`, a good `start`, and a 64-bar `peaks` waveform.

Two findings for Connor: **Clair de lune (Goedhart) is CC BY 3.0, not public domain** (the Commons page's
recording licence; `~/Developer/monetshot-music/keep/README.md` says PD), and the Commons *Gnossienne No. 1*
is CC BY-SA. Neither ships.

**A browser that helps you choose (both apps).** The browser docks on the right, over the inspector, so the
video stays in view. Shelves: *For this video* (`MusicSuggest.rank`: the format's mood, length (a track that
would loop sinks), vertical = punchier, favourites lifted), *Favourites*, the six moods; Tempo chips (calm,
steady, upbeat); search. Every row: cover, title, artist · mood · tempo, length, heart, Use, and a waveform
with the stretch that would play under this video lit. **Click a row and it plays under your own video**
(the editor's own player on the Mac, the preview's clock on the desktop), from where Use would put it; the
waveform's playhead follows. Favourites are remembered (UserDefaults; the webview's storage). *Your own*
file stays. The desktop preview now plays the music at all (it didn't before), with the same envelope.

**Music that fits the edit (both Kits, same math, fixtures).**
- `MusicFit.place`: start on the downbeat at the track's good start (its first lift for a vertical video),
  moved on by up to three bars so the end fade begins on a phrase line (every 4 bars); inside the song when it
  fits. `MusicFit.outro`: the fade lasts from that phrase line to the end (a bar or two; never over a third of
  the video), worked out at render time from the track's grid, so a trimmed video still ends on a phrase.
  Tracks without a beat (the classical ones) keep the plain 2 s fade from the top.
- `VoiceActivity`: talk found by level alone (50 ms frames, above the take's own quiet by 12 dB, between -48
  and -26 dBFS; pauses under 0.5 s bridged, bursts under 0.2 s ignored). The music ducks (to 30 %) under any
  voice in the edit, the camera's mic or the take's voice track from captions (`meta.voice`): the Mac reads
  each piece of the camera and voice tracks (`TrackID.overlayAudio`, `takeCameraAudio`, `takeVoice`) at its
  place on the output clock; the desktop reads its voices mix (camera audio + `subtitles::voice_audio`)
  before the music goes in.
- A file of your own gets its grid read once and kept with the choice (`track.grid`).
- `--music` on the Mac command line fits the same way.

## How it was proven

| | Mac | Linux / Omarchy | Windows |
|---|---|---|---|
| Kit logic | MonetShotChecks (fit, phrase lines, voice ranges, suggestions, library: 43 tracks, moods, tempos, size) | fixtures `music_fit.json` (voice levels and ranges, place/outro over 4 grids x 2 songs x 5 lengths, suggestions, tempos), `music_envelope.json` (outros) in cargo test | same cargo tests |
| Export with music | `--music` then `--render` on a copy of a real recording, Night Driving placed from 5.08 s (2 bars), end fade 4.65 s from a phrase line; earshot: -15.3 LUFS, -1.6 dBTP | `music_ducks_under_a_voice` (export crate) | CI VM: the editor check's export carries the music (ebur128 in windows-run) |
| Duck under voice | same export with a spoken camera clip at 4.0-14.1 s (macOS `say`), rendered with the duck on and off: the difference is exactly 3.55-14.45 s (the 0.45 s ramps), -10.5 dB, zero elsewhere | the export test: talk found at 2-5 s by level, the music's 220 Hz tone x0.2-0.45 under it, back after | the same test in cargo test on Windows |
| Browser | snapshot `docs/v0.2/status/music-mac-browser.jpg` (Day Trips playing under the video) | editor.js in Hyprland (container) | editor.js on the CI VM + screenshot `2-music.png` (artifact `windows-run`) |

## Not proven

- Nobody has listened. earshot judged every track (and taste is Connor's call: `music-picks.md` has the
  evidence and the shortlist of doubts: Night Life's realness is borderline, several lo-fi tracks carry hiss by
  design).
- Ducking under a real voice on Windows/Linux hardware (the CI VM take has no mic; the export test uses a
  tone; the Mac test used `say`, a synthetic voice).
- The vertical shelf (punchier picks, starting at the first lift) is unit-tested; a real 9:16 edit needs the
  vertical branch.
- Ducking under captions' voice track (`meta.voice`) is wired on both sides (it is one of the tracks read)
  but no take with a separate voice file was exported to measure it; the measured case is camera sound.

## Fixes outside music (small, needed for the duck)

- `Composer.addCamera` laid a camera clip that starts after 0 on an empty track at 0 (its picture and sound),
  so a clip recorded at 4 s played from 0 s. It now opens the gap before the first piece.
- Windows: library tracks' `file:///D:/...` URLs became `/D:/...` paths. Fixed in the page (`music.ts`
  `urlPath`); for `media.rs` this branch carries feat/vertical's identical fix (`69935b8`, cherry-picked) so the
  merge has one copy. Also cherry-picked: vertical's `1f1378d` (windows-run stages 3 and 6 had failed on v0.2
  itself since 2811c92: fixtures-test gave the painter no textArt; a console window sat over the pill).
- What the Windows VM export taught: Day Trips placed from its first downbeat gave a 5 s video only its
  filtered intro (earshot: -27.8 LUFS, 3.2 kHz wide, against -24.7 LUFS for those 5 s of the track). Each
  track's `start` is now the first bar line where it's in full swing.

## Merge notes

- Already merged with `v0.2` = `main` at 28bafb4 (merge commit on this branch). Conflicts were in
  `Composer.swift` (`voice(in:)`: this branch's level reading kept, limited to the camera and voice tracks),
  `playback.ts` (captions' voice elements and this branch's music element both kept), README and spec (both
  sections kept; the old incompetech text dropped), `shared/LAST_SYNC` (regenerated). Fixtures regenerated
  after the merge: only `music.json`, `music_envelope.json` and the new `music_fit.json` differ from v0.2.
- `media.rs` keeps vertical's Windows file-URL fix (cherry-picked earlier, so it merged as the same change).
- `Resources/Music` replaces 0.2.0's 20 files (43 tracks, 76 MB; three of the 20 left out, see music-picks).
  Existing recordings keep working: their music file is a copy inside the .reel.
- The library is the only large change; git history grows by ~76 MB.
