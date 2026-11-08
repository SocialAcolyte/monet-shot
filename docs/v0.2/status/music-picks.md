# Music picks for 0.2: why each track is in

43 tracks, all CC0 1.0 or public domain (licence checked on each track's own page, 2026-11-07/08; the page
URL is in `Resources/Music/library.json` as proof in case of a claim). Every number below is earshot's reading
of the file as shipped (trimmed, levelled, AAC 96 kbps), judged in one process (`scratch/tools/judge.py`,
the same models as the earshot MCP tools):

- **q**: z for "warm modern well-produced instrumental music with real instruments" (>= 3 strong, 2.5-3 plausible).
- **risks**: z for cheese ("cheesy upbeat corporate stock music with ukulele, whistling and handclaps"), chiptune,
  tape hiss and sung vocals; a pick needed every risk under 2.5 (or a reason written here).
- **real**: earshot realness on the whole file (p_real; long-file thresholds lo 0.40 / hi 0.77).
- **energy** = 0.5 + 0.12 x (z punchy - z calm), clamped 0.05-0.95: what the suggestions use.
- **LUFS / dBTP**: measured after levelling (target -16 LUFS integrated, -1.5 dBTP before AAC).

Taste is not measured: earshot says what a track is and how it measures, not whether it is beautiful.
Connor decides; these are the evidence and the reasons.

| # | Track | Artist | Licence | Moods | Tempo | Energy | q | cheese | chip | hiss | vocals | real | LUFS | dBTP | sounds most like |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | [Lost On The Freeway](https://freemusicarchive.org/music/holiznacc0/lost/lost-on-the-freeway/) | HoliznaCC0 | CC0 1.0 | grooving, sunny, punchy | steady | 0.64 | +2.6 | +1.9 | +0.4 | +3.2 | +0.9 | 0.929 | -16.0 | -2.9 | funk music (z +3.8) |
| 2 | [Night Driving](https://freemusicarchive.org/music/holiznacc0/only-in-the-milky-way-part-3/night-driving/) | HoliznaCC0 | CC0 1.0 | dreamy, grooving | steady | 0.32 | +2.2 | +1.4 | -0.1 | +3.1 | +1.2 | 0.843 | -16.0 | -0.6 | lo-fi hip hop beat (z +3.9) |
| 3 | [Night Life](https://freemusicarchive.org/music/holiznacc0/waves-of-nostalgia-2/night-life/) | HoliznaCC0 | CC0 1.0 | dreamy, grooving | steady | 0.44 | +1.6 | +0.8 | +1.2 | +2.0 | +1.9 | 0.755 | -16.4 | -2.6 | lo-fi hip hop beat (z +3.2) |
| 4 | [Lofi Jam](https://freemusicarchive.org/music/John_Bartmann/moody-beats/lofi-jam/) | John Bartmann | CC0 1.0 | mellow, grooving | calm | 0.42 | +2.2 | +1.0 | +0.3 | +1.7 | +0.7 | 0.946 | -16.0 | -1.9 | lo-fi hip hop beat (z +3.2) |
| 5 | [Day Trips](https://freemusicarchive.org/music/holiznacc0/city-slacker/day-trips/) | HoliznaCC0 | CC0 1.0 | sunny, mellow | steady | 0.52 | +2.1 | +1.6 | +0.4 | +1.7 | +0.1 | 0.919 | -16.0 | -0.4 | funk music (z +4.2) |
| 6 | [Summer Pride](https://freemusicarchive.org/music/Loyalty_Freak_Music/INSTRUMENTAL_RB_BEATS_TO_SING_OR_RAP_ON/Loyalty_Freak_Music_-_INSTRUMENTAL_RB_BEATS_TO_SING_OR_RAP_ON_-_17_Summer_Pride/) | Loyalty Freak Music | CC0 1.0 | mellow | calm | 0.35 | +2.2 | +1.5 | +1.0 | +3.2 | +0.9 | 0.922 | -16.0 | -3.9 | jazz music (z +4.0) |
| 7 | [Sky Scrapers](https://freemusicarchive.org/music/holiznacc0/city-slacker/sky-scrapers/) | HoliznaCC0 | CC0 1.0 | dreamy | calm | 0.32 | +2.2 | +0.9 | +0.3 | +2.4 | +0.6 | 0.873 | -16.0 | -5.0 | jazz music (z +3.2) |
| 8 | [Make Love](https://freemusicarchive.org/music/holiznacc0/bassic/make-love/) | HoliznaCC0 | CC0 1.0 | grooving | steady | 0.69 | +2.5 | +1.8 | -0.0 | +2.5 | +1.1 | 0.978 | -16.0 | -3.5 | funk music (z +4.3) |
| 9 | [Dancing](https://freemusicarchive.org/music/holiznacc0/only-in-the-milky-way-part-2/dancing/) | HoliznaCC0 | CC0 1.0 | mellow, dreamy | calm | 0.36 | +1.5 | +0.6 | -0.5 | +4.1 | +1.5 | 0.905 | -16.4 | -0.9 | lo-fi hip hop beat (z +4.0) |
| 10 | [Don't Ride the Dolphin](https://freemusicarchive.org/music/Tequila_Moonrise/I_hate_myself_and_i_want_to_tie_and_dye/Tequila_Moonrise_-_I_hate_myself_and_I_want_to_tie_and_dye_-_03_Dont_ride_the_Dolphin/) | Tequila Moonrise | CC0 1.0 | dreamy | upbeat | 0.51 | +1.8 | +1.2 | +0.9 | +3.5 | +2.2 | 0.903 | -16.0 | -2.3 | indie pop music (z +3.0) |
| 11 | [Monarch of the Street](https://freemusicarchive.org/music/Loyalty_Freak_Music/TO_CHILL_AND_STAY_AWAKE/Loyalty_Freak_Music_-_TO_CHILL_AND_STAY_AWAKE_-_07_Monarch_of_the_street/) | Loyalty Freak Music | CC0 1.0 | sunny, grooving | steady | 0.76 | +2.9 | +2.1 | +1.1 | +2.3 | +0.2 | 0.982 | -15.9 | -2.6 | funk music (z +4.7) |
| 12 | [Disco in the Sky](https://freemusicarchive.org/music/John_Bartmann/eurodisco-party-heaven/disco-in-the-sky/) | John Bartmann | CC0 1.0 | sunny | upbeat | 0.4 | +2.1 | +1.2 | +1.9 | +1.4 | +1.2 | 0.96 | -16.0 | -2.8 | jazz music (z +3.2) |
| 13 | [Moving Forward](https://freemusicarchive.org/music/holiznacc0/city-slacker/moving-forward/) | HoliznaCC0 | CC0 1.0 | mellow | calm | 0.17 | +1.9 | +0.7 | -0.4 | +3.1 | +1.1 | 0.915 | -16.0 | -3.8 | lo-fi hip hop beat (z +4.7) |
| 14 | [Danse sacrée](https://commons.wikimedia.org/wiki/File:Danse_Sacrée.ogg) | Debussy · US Marine Chamber Orchestra | Public domain | classical | calm | 0.05 | +0.8 | +0.6 | +1.2 | +1.2 | +1.2 | 0.962 | -15.9 | -1.3 | classical string quartet (z +3.8) |
| 15 | [Danse profane](https://commons.wikimedia.org/wiki/File:Danse_Profane.ogg) | Debussy · US Marine Chamber Orchestra | Public domain | classical | calm | 0.08 | +1.0 | +0.7 | +1.1 | +1.1 | +0.8 | 0.968 | -16.0 | -1.3 | classical string quartet (z +3.8) |
| 16 | [Gymnopédie No. 1](https://commons.wikimedia.org/wiki/File:Erik_Satie_-_gymnopedies_-_la_1_ere._lent_et_douloureux.ogg) | Satie · Robin Alciatore | Public domain | classical, mellow | calm | 0.05 | +1.4 | +0.1 | +0.6 | +1.9 | +1.5 | 0.977 | -16.0 | -1.1 | sad and melancholic music (z +4.7) |
| 17 | [Born to Boogie](https://freemusicarchive.org/music/John_Bartmann/eurodisco-party-heaven/born-to-boogie/) | John Bartmann | CC0 1.0 | punchy, grooving | upbeat | 0.95 | +0.3 | +0.2 | +1.3 | +2.0 | +1.9 | 0.971 | -16.0 | -2.3 | funk music (z +4.6) |
| 18 | [Party Party Disco Party](https://freemusicarchive.org/music/John_Bartmann/eurodisco-party-heaven/party-party-disco-party/) | John Bartmann | CC0 1.0 | punchy | upbeat | 0.95 | +0.2 | +0.2 | +1.7 | +0.8 | +1.6 | 0.99 | -16.0 | -3.5 | techno music (z +3.7) |
| 19 | [Rich Mahogany](https://freemusicarchive.org/music/John_Bartmann/eurodisco-party-heaven/rich-mahogany/) | John Bartmann | CC0 1.0 | punchy, grooving | upbeat | 0.7 | +1.2 | +0.3 | +1.1 | +1.9 | +0.7 | 0.938 | -16.0 | -1.3 | tech house music (z +3.7) |
| 20 | [Autotune Will Not Save You](https://freemusicarchive.org/music/John_Bartmann/eurodisco-party-heaven/autotune-will-not-save-you/) | John Bartmann | CC0 1.0 | punchy | upbeat | 0.89 | +0.4 | -0.0 | +2.0 | +1.5 | +1.7 | 0.976 | -16.0 | -3.6 | techno music (z +4.3) |
| 21 | [Back In The 80s](https://freemusicarchive.org/music/holiznacc0/power-pop/back-in-the-80s/) | HoliznaCC0 | CC0 1.0 | punchy, sunny | upbeat | 0.77 | +2.0 | +0.5 | +0.4 | +2.0 | +0.6 | 0.936 | -16.0 | -2.0 | techno music (z +4.1) |
| 22 | [Rusty Bicycle](https://freemusicarchive.org/music/John_Bartmann/softly-boldly-with-a-piano/rusty-bicycle/) | John Bartmann | CC0 1.0 | mellow, classical | calm | 0.05 | +1.0 | +0.7 | +1.6 | +0.5 | +0.4 | 0.934 | -16.0 | -1.8 | solo piano music (z +4.4) |
| 23 | [Guessing Game](https://freemusicarchive.org/music/John_Bartmann/softly-boldly-with-a-piano/guessing-game/) | John Bartmann | CC0 1.0 | mellow | calm | 0.05 | +1.1 | +0.5 | +1.6 | +0.7 | +0.8 | 0.923 | -16.0 | -2.0 | solo piano music (z +4.2) |
| 24 | [Winter Rain](https://freemusicarchive.org/music/John_Bartmann/softly-boldly-with-a-piano/winter-rain/) | John Bartmann | CC0 1.0 | mellow, dreamy | calm | 0.05 | +1.6 | +0.7 | +1.6 | +0.8 | +1.1 | 0.948 | -16.0 | -1.3 | sad and melancholic music (z +4.0) |
| 25 | [Grassroots Programming](https://freemusicarchive.org/music/John_Bartmann/machine-learning/grassroots-programming/) | John Bartmann | CC0 1.0 | dreamy | steady | 0.24 | +2.1 | +1.4 | +0.2 | +3.2 | +0.8 | 0.975 | -16.0 | -1.1 | warm and cozy music (z +3.3) |
| 26 | [Self-Driving Nights](https://freemusicarchive.org/music/John_Bartmann/machine-learning/self-driving-nights/) | John Bartmann | CC0 1.0 | dreamy | upbeat | 0.56 | +1.5 | +0.8 | +0.7 | +2.5 | +1.1 | 0.95 | -16.0 | -2.0 | house music (z +3.7) |
| 27 | [Spirit Of Java](https://freemusicarchive.org/music/John_Bartmann/single/spirit-of-java/) | John Bartmann | CC0 1.0 | grooving, dreamy | steady | 0.48 | +2.3 | +1.4 | +0.4 | +2.4 | +0.8 | 0.989 | -15.9 | -2.7 | drum and bass music (z +2.9) |
| 28 | [Back To Basics](https://freemusicarchive.org/music/John_Bartmann/single/back-to-basics/) | John Bartmann | CC0 1.0 | punchy, grooving | upbeat | 0.76 | +2.4 | +1.3 | +1.1 | +2.2 | +0.6 | 0.987 | -16.0 | -5.8 | techno music (z +3.2) |
| 29 | [The Last Long Day](https://freemusicarchive.org/music/holiznacc0/summer-air-lo-fi/the-last-long-day/) | HoliznaCC0 | CC0 1.0 | dreamy, mellow | calm | 0.26 | +3.2 | +1.5 | -0.7 | +2.3 | +0.6 | 0.946 | -16.0 | -0.4 | dreamy and ethereal music (z +3.4) |
| 30 | [Roof Tops](https://freemusicarchive.org/music/holiznacc0/summer-air-lo-fi/roof-tops/) | HoliznaCC0 | CC0 1.0 | dreamy | calm | 0.08 | +2.4 | +1.3 | -0.5 | +2.2 | +1.2 | 0.958 | -16.0 | -0.9 | sad and melancholic music (z +3.8) |
| 31 | [Hope On Repeat](https://freemusicarchive.org/music/holiznacc0/spring-woke-me-up/hope-on-repeat/) | HoliznaCC0 | CC0 1.0 | sunny, mellow | calm | 0.38 | +2.4 | +1.1 | +0.3 | +2.5 | +0.9 | 0.955 | -16.4 | -1.9 | lo-fi hip hop beat (z +3.6) |
| 32 | [Spring In Sight](https://freemusicarchive.org/music/holiznacc0/spring-woke-me-up/spring-in-sight/) | HoliznaCC0 | CC0 1.0 | sunny, mellow | calm | 0.34 | +2.2 | +1.5 | -0.5 | +2.4 | +0.8 | 0.984 | -16.4 | -2.6 | lo-fi hip hop beat (z +3.3) |
| 33 | [Spring On The Horizon](https://freemusicarchive.org/music/holiznacc0/background-music/spring-on-the-horizon/) | HoliznaCC0 | CC0 1.0 | dreamy, classical | calm | 0.07 | +1.9 | +0.9 | +0.9 | +0.7 | +1.1 | 0.937 | -16.0 | -2.7 | dreamy and ethereal music (z +3.7) |
| 34 | [People Are Spinning](https://freemusicarchive.org/music/Loyalty_Freak_Music/TO_CHILL_AND_STAY_AWAKE/Loyalty_Freak_Music_-_TO_CHILL_AND_STAY_AWAKE_-_06_People_are_spinning/) | Loyalty Freak Music | CC0 1.0 | dreamy, grooving | steady | 0.24 | +2.9 | +1.7 | +0.7 | +2.5 | +1.3 | 0.935 | -16.0 | -4.4 | dreamy and ethereal music (z +3.9) |
| 35 | [Chillin With a Drink at the Club](https://freemusicarchive.org/music/Loyalty_Freak_Music/TO_CHILL_AND_STAY_AWAKE/Loyalty_Freak_Music_-_TO_CHILL_AND_STAY_AWAKE_-_03_Chillin_with_a_drink_at_the_club/) | Loyalty Freak Music | CC0 1.0 | grooving | steady | 0.54 | +2.2 | +1.8 | +1.1 | +2.6 | +0.1 | 0.977 | -16.0 | -1.9 | jazz music (z +4.8) |
| 36 | [Lag](https://freemusicarchive.org/music/Loyalty_Freak_Music/MINIMAL_AMBIENT_BOUNCE/Loyalty_Freak_Music_-_MINIMAL_AMBIENT_BOUNCE_-_06_Lag/) | Loyalty Freak Music | CC0 1.0 | dreamy, mellow | calm | 0.18 | +2.5 | +0.9 | +0.9 | +2.3 | +1.1 | 0.845 | -16.0 | -1.1 | dreamy and ethereal music (z +3.4) |
| 37 | [No Cadillac](https://freemusicarchive.org/music/Loyalty_Freak_Music/MINIMAL_AMBIENT_BOUNCE/Loyalty_Freak_Music_-_MINIMAL_AMBIENT_BOUNCE_-_07_No_Cadillac/) | Loyalty Freak Music | CC0 1.0 | dreamy, mellow | steady | 0.24 | +2.5 | +0.7 | +0.9 | +1.2 | +0.7 | 0.91 | -15.8 | -1.0 | dreamy and ethereal music (z +3.4) |
| 38 | [Rhythm Factory](https://freemusicarchive.org/music/zane-little/digital-cocktail/rhythm-factory/) | Zane Little | CC0 1.0 | punchy | upbeat | 0.95 | +1.8 | +0.8 | +1.2 | +1.2 | +0.7 | 0.986 | -15.7 | -1.5 | funk music (z +3.7) |
| 39 | [Goober Dynamics 1](https://freemusicarchive.org/music/zane-little/digital-cocktail/goober-dynamics-1/) | Zane Little | CC0 1.0 | punchy, grooving | upbeat | 0.85 | +1.8 | +0.8 | +1.1 | +2.0 | +0.3 | 0.988 | -17.0 | -2.2 | funk music (z +3.3) |
| 40 | [Goldberg Variations: Aria](https://commons.wikimedia.org/wiki/File:Kimiko_Ishizaka_-_J.S._Bach-_-Open-_Goldberg_Variations,_BWV_988_(Piano)_-_01_Aria.mp3) | Bach · Kimiko Ishizaka | CC0 1.0 | classical, mellow | calm | 0.05 | +0.4 | -0.2 | +0.8 | +1.6 | +1.2 | 0.987 | -16.0 | -1.3 | solo piano music (z +4.6) |
| 41 | [Prelude in C major](https://commons.wikimedia.org/wiki/File:Kimiko_Ishizaka_-_Bach_-_Well-Tempered_Clavier,_Book_1_-_01_Prelude_No._1_in_C_major,_BWV_846.ogg) | Bach · Kimiko Ishizaka | CC0 1.0 | classical, mellow | calm | 0.05 | +1.4 | -0.1 | +0.4 | +1.4 | +1.0 | 0.988 | -16.0 | -1.4 | solo piano music (z +4.5) |
| 42 | [Nocturne in E-flat, Op. 9 No. 2](https://commons.wikimedia.org/wiki/File:Nocturne_Op._9_no._2_in_E_flat_major.mp3) | Chopin · Musopen | CC0 1.0 | classical, dreamy | calm | 0.05 | +0.4 | +0.0 | +0.9 | +0.6 | +1.0 | 0.974 | -16.0 | -1.3 | solo piano music (z +4.3) |
| 43 | [Nocturne in F-sharp, Op. 15 No. 2](https://commons.wikimedia.org/wiki/File:Chopin_-_Nocturne_No._5_in_F-sharp_major,_Op._15_No._2_(Luke_Faulkner).flac) | Chopin · Luke Faulkner | Public domain | classical | calm | 0.12 | +1.1 | -0.2 | +0.3 | +1.3 | +1.2 | 0.991 | -15.9 | -1.3 | solo piano music (z +4.6) |

## Why the risk readings above 2.5 are still in

- **Tape hiss (z 2.5-4.1)**: Dancing, Don't Ride the Dolphin, Lost On The Freeway, Summer Pride, Grassroots
  Programming, Night Driving, Moving Forward, Make Love, Chillin With a Drink, Hope On Repeat, Spring In Sight,
  People Are Spinning. The lo-fi grain is part of these tracks' sound (and most are Connor's own picks from his
  work in progress). Their measured noise floors are -22 to -36 dBFS under a -16 LUFS track: texture, not
  noise. Tracks whose hiss was the whole story (Cold Salt Water, Bus Stop, Nowhere To Be, Dreams, Studio
  Apartment: z 3.2-3.9 with clipped masters or "uncertain" realness) were left out.
- **Night Life**: realness "uncertain" (p 0.755, just under the 0.77 line for long files) after levelling; it read
  0.685 before the gentler re-encode. Kept because it is in Connor's own selection; first to go if he
  disagrees.

## How the library was made

1. **Sources.** Connor's 20 (`~/Developer/monetshot-music`: candidates.json, his notes) and his 16 "slap"
   tracks, plus 103 new FMA candidates from the CC0 artists the brief names (John Bartmann: Softly Boldly With
   A Piano, Machine Learning, Picnic On The Seine, Happy Trappy, singles; HoliznaCC0: Summer Air, Ocean Memory,
   Spring Woke Me Up, City Slacker, Background Music, Only In The Milky Way, Power Pop!, Interstellar Pop Songs,
   Lullabies; Loyalty Freak Music: Positive Attitude!, Minimal Ambient Bounce, To Chill and Stay Awake, Roller
   Disco; Zane Little: Digital Cocktail, New Peach Radio) and 6 public-domain / CC0 piano recordings from
   Wikimedia Commons. Every FMA track page was read for its licence block (CC0 1.0 link and wording) and its
   "AI generated?" answer (all picks: No). Pixabay was not used.
2. **Judging.** earshot ranked every candidate on the quality query and the risks (cheese, chiptune, hiss,
   vocals), plus energy queries (punchy, calm, dreamy, groove, piano); realness and meters on each. Rejects were
   deleted as each batch was judged.
3. **Making the files** (`scratch/tools/build_library.py`, not shipped): a song up to 2:50 keeps its own ending;
   a longer one ends on a phrase line (every 4 bars of the Kit's own beat grid) between 1:52 and 2:35, with a
   fade over the last two bars; a piano or orchestral piece ends at its quietest half second between 2:00
   and 2:35 with a 5 s fade. Two-pass loudnorm to -16 LUFS / -1.5 dBTP (-5 dBTP for five hot, clipped
   masters, so the AAC decode stays under -1.5 dBTP), AAC 96 kbps 44.1 kHz stereo. 43 files, 76 MB.
4. **The fit data** is read from the shipped file by MonetShotKit itself (`MusicGrid.analyze`,
   `MusicCatalog.waveform`): beat grid (bar, first downbeat, lifts), 64-bar waveform. The seven classical
   recordings carry no grid (rubato: there is no steady bar to fit), so they start at the top and end on the
   plain 2 s fade.
5. **Then judged again as shipped** (the table above), and one more cut: **Venus** (HoliznaCC0) read
   "inspirational corporate background music" z +2.8 as its second-strongest genre and "sad and melancholic"
   rather than the sunny it was picked for.

## Considered and left out

| Track | Why |
|---|---|
| Butterflies, Lovebug (Zane Little) | sung vocals (compete with a voice-over) and possibly AI-made: "[Verse1]" lyric tags, no answer to FMA's AI question when Connor checked |
| Unwind (HoliznaCC0) | ukulele and hiss (the brief: no stock ukulele) |
| Midnight Cruiser (Zane Little) | band-limited to 10 kHz, a game-music feel |
| Clair de lune (Laurens Goedhart) | **not public domain**: the Commons page's recording licence is CC BY 3.0 (the permission line quotes Goedhart's SoundCloud). `keep/README.md` calls it public domain; it needs a credit, so it can't ship in a no-credit library |
| Gnossienne No. 1 (La Pianista, Commons) | the composition is PD but the performance is CC BY-SA 3.0 / GFDL |
| Nova Serenade, Allez! Allez!, Picnic On The Seine, Mellow Cafe Vibe (John Bartmann) | "cheerful ukulele music" was their closest reading (z +3.2-3.4) |
| Yippee!, Hug Convoy, Ice Cream With You, Go to the Picnic (Loyalty Freak) | ukulele z +3.9-4.5, cheese z +2.9-3.8 |
| Apple Cider, The Way It Is, Roller Fever (Zane Little / LFM) | "upbeat corporate pop" / chiptune risk z 2.2-3.6 |
| Electronic Outlaw, Sweat Time, Can't Stop My Feet, Retro Synths, Bouncing, Day Dreams | chiptune z +2.6 to +4.3 |
| On A Breeze, Annabelle's Theme, A Secret Comes Out (John Bartmann), Old Key, Once More With You, One Cool Minute (LFM), Love (HoliznaCC0) | realness uncertain or "likely code-synthesized" (p 0.16-0.67) |
| Lo-fi batch (Cold Salt Water, Bus Stop, Nowhere To Be, Dreams, Studio Apartment, Deja Vu, Fresh Fit, Hooptie...) | hiss z 3.1-3.9 with clipped masters (381-6087 clipped samples) |
| Gamer / Music Box / Creepy Piano albums | not demo music |
