# IPC contract (app)

Owner: **ms-app**. Tauri 2 commands (UI → Rust) and events (Rust → UI) of
`desktop/app`. Code: `desktop/app/src-tauri/src/commands.rs`; typed on the UI
side in `desktop/app/ui/src/lib/ipc.ts` (which also mocks them in a plain
browser, so pages open in Safari for checking).

Names are snake_case commands, kebab-case events; payloads camelCase JSON.

## Windows

One page, `index.html?view=…`:

| Label | View | Notes |
|---|---|---|
| `home` | `home` | 980×680, min 620×440 |
| `editor-N` | `editor&reel=<abs path>` | one per recording, 1320×860, min 980×640 |
| `pill` | `pill` | title "Monet Shot Pill"; always on top, transparent, no decorations, content-protected (kept out of captures on Windows/macOS), shown whenever the record state isn't idle or a problem is showing |
| `picker` | `picker` | title "Monet Shot Picker"; our display/window picker where the backend has no system picker (Windows, macos-dev). Closing it = cancel |
| `bubble` | `bubble` | title "Monet Shot Camera"; 200×200 round camera preview, bottom-right, during a 3-2-1 with "Record My Camera Too"; ignores the mouse; gone when recording starts |

## Record state

```ts
type Phase =
  | { kind: "idle" } | { kind: "picking" } | { kind: "countdown"; n: number }
  | { kind: "starting" } | { kind: "recording"; since: number /* ms epoch */ }
  | { kind: "saving" };
interface BarState {
  phase: Phase; paused: boolean;
  pausedTotal: number;          // ms paused so far
  pausedSince: number | null;   // ms epoch, current pause
  problem: string | null;       // "Couldn't record", 4 s
  cameraToo: boolean;           // "Record My Camera Too"
}
```

| Command | Args | Returns | Does |
|---|---|---|---|
| `bar_state` | | `BarState` | |
| `bar_tap` | | | the ring: idle → pick, countdown → cancel (as the Mac's `tap`) |
| `bar_cancel` | | | cancel picking/countdown |
| `bar_toggle_pause` | | | pause/resume while recording |
| `bar_stop` | | | stop (the pill times the 0.6 s hold itself) |
| `show_home` | | | open/focus Home |
| `picker_sources` | | `SourceView[]` | `{id, kind: "display"\|"window", title, app, width, height, thumbnail: data-URL\|null}` |
| `picker_choose` | `id: string\|null` | | the picker's answer; null = cancelled |
| `camera_preview` | `channel: Channel<ArrayBuffer>` | | subscribes the page to the shared camera's preview: raw JPEG per message, ~30 fps, while some owner holds the camera |

| Event | Payload | When |
|---|---|---|
| `bar` | `BarState` | every change |
| `take-finished` | `{project: string, clips: Clip[]}` | a take recorded into a project is saved; that project's editor adds `clips` at the end |

## Command line

- `monet-shot status [--waybar] [--follow]`: prints the status (JSON, or
  Waybar's `{"text","tooltip","class","alt"}`), no app started.
- `monet-shot toggle`: idle → record, picking/countdown → cancel,
  recording → stop (no hold: a bar click is deliberate).
- `monet-shot pause`: pause/resume.
- A second launch forwards its arguments to the running app
  (single-instance); with none it shows Home.

The app publishes `monetshot_capture::status` on every change and once a
second while recording, and clears it on quit.

## Editor

| Command | Args | Returns | Does |
|---|---|---|---|
| `editor_load` | `path` | `{folder, name, title, edit, takes: [{meta, cursor, dir, video, camera}]}` | reads a .reel for the page (core-wasm takes meta/cursor/dir) |
| `editor_save` | `path, edit` | | writes edit.json with core's writer (Mac-identical) |
| `filmstrip` | `video, duration` | `{path, count, cols, tileW, tileH, step}` | a JPEG tile sheet, a frame per 0.5 s (≤400), cached in support/filmstrips |
| `backdrop_gallery` | | `[{file, title, artist, licence, source, path, thumb}]` | the 20 paintings (bundled Backdrops, or the repo's in dev) |
| `backdrop_copy` | `folder, from, name?` | `string` | copies a picture into the recording; returns its name there |
| `recording_remove_file` | `folder, name` | | deletes a file the edit no longer uses (name only, no paths) |
| `add_footage` | `folder, paths, edit` | `{edit: Edit\|null, videoTakes: number[]}` | imports videos as takes / other recordings with their clips + zooms |
| `export_start` | `folder` | `string` (the .mp4) | renders beside the .reel; `export-progress` events |
| `record_take` | `path` | | records a new take into this recording |
| `home_items` / `home_thumb` / `open_recording` / `reveal` / `trash` / `import_video` | | | Home (see home.rs) |
| `ui_log` | `level, message` | | a page line into the app log (page errors go here) |

| Event | Payload | When |
|---|---|---|
| `export-progress` | `{folder, progress: 0..1}` | while exporting (≤ 1 % steps) |
| `library-changed` | | a recording was added, imported or trashed |

## Developer aids

- `MONETSHOT_HOME=<dir>`: everything under that dir (as the Mac).
- `MONETSHOT_DEMO_RECORD=1`: clicks the ring a second after launch, records
  the first display without the picker, and leaves the pill capturable by
  screenshots. `MONETSHOT_DEMO_STOP=<s>` then stops the take after s seconds.
- `monet-shot <path.reel>` opens that recording's editor.
- `MONETSHOT_SNAPSHOT_TIME=<s>`, `_SELECT=<zoom>`, `_CLIP=<clip>`,
  `_FRAMING=blur|crop`, `_MUSIC=1`, `_SCROLL=bottom`, `_EXPORT=1`: open the
  editor in that state (as the Mac's snapshot aids).
- `MONETSHOT_DEV_PAGE=fixtures-test.html`: opens a dev page from the Vite
  server; the painter-vs-Mac numbers go to the log.
- `MONETSHOT_DEV_SCRIPT=<abs .js>`: dev builds run it in every page;
  `ui/devchecks/editor.js` clicks through the editor and logs ok/FAIL.
- `window.monetshot` is the EditorStore in dev builds.

## Editor media (ms-capture)

Owner of this section: **ms-capture**. Code: `src-tauri/src/media.rs` and
`src-tauri/src/camera.rs`; UI in `ui/src/editor/camera/*`,
`ui/src/editor/music/*`, `ui/src/views/Bubble.svelte`, `ui/src/lib/camera.ts`.
Ports the camera/music parts of the Mac's EditorModel, CameraOverlay,
CameraRecorder, MusicBrowser* and MusicCatalog.

### Camera

One shared camera (`camera.rs`), held by owners: `"bar"` (the 3-2-1 bubble)
and `"editor:<folder>"` (an editor's camera mode). Preview frames reach
every page subscribed with `camera_preview` (above).

| Command | Args | Returns | Does |
|---|---|---|---|
| `camera_open` | `owner` | `bool` | turn the camera on for `owner`; false = no camera / in use |
| `camera_close` | `owner` | | release it; off when nobody holds it |
| `camera_devices` | | `{cameras, microphones: {id,name}[], camera, mic}` | lists + the remembered choice (null = default) |
| `camera_use` | `camera, mic` | | switch device, remembered (`state_dir/camera.json`); also used by "Record My Camera Too" |
| `camera_record` | `folder, file` | | start `<folder>/<file>` (`camera-<unix>.mp4`, H.264 + AAC); resolves at its first frame |
| `camera_stop` | | `{file, duration} \| null` | finish the file |
| `camera_take` | `folder, file` | | "Just me": the file becomes the next `take-N/screen.mp4` (source `import`); then `store.takesAdded({zooms:false})` |

Flow (`camera/flow.ts`, the Mac's): open → `ready` → Space: 3-2-1 (0.8 s
each) → `camera_record` → `recording` (over the video: the edit plays
muted from the playhead) → Space → `saving` → `camera_stop` →
over the video: `cameraClips` gets `{file, at, duration ≤ rest of video}`
via `cameraInsert`; just me: `camera_take`; under 0.3 s: the file is
removed → camera closes.

### Music

The library is `Resources/Music/library.json` + its files (bundled as
`Music/`; the repo's in dev), CC0 / public domain, offline.

| Command | Args | Returns | Does |
|---|---|---|---|
| `music_library` | `query, mood` | `Song[]` | all words must match; else the mood's feel; else all |
| `music_own_file` | `path` | `Song` | a file you have the rights to (`license: "own"`) |
| `music_add` | `folder, song` | file name | copies it into the recording (`music-<id>.<ext>`); the page sets `edit.music` (keeping the old volume/fades) and removes the old file |
| `music_shape` | `folder, file` | `{wave: number[240], grid: {bar, firstDownbeat, lifts} \| null}` | waveform + beat grid for the snippet picker (one ffmpeg decode at 11025 Hz) |

Preview playback in the browser uses an `<audio>` on the asset protocol.

### Media over loopback HTTP (Linux)

| Command | Args | Returns | Does |
|---|---|---|---|
| `media_url` | `path` | `http://127.0.0.1:<port>/<token>/<name>` | a URL WebKitGTK's player can stream: Tauri's asset:// fails there for `<video>`/`<audio>` (FormatError; 403 under hidden dirs). Use on Linux with `crossOrigin = "anonymous"`; asset:// elsewhere |
| `media_release` | | | revoke every token the calling window holds |

Rust: `media::release(label)`, call on the window's `Destroyed` event.

The server binds 127.0.0.1 on a random port and serves only registered
files, each under a 244-bit token from the OS's random source, owned by the
window that asked. Requests must be exactly `/<token>/<name>` with no query;
Host must be `127.0.0.1:<port>` (else 421, against DNS rebinding); an Origin
other than `tauri://localhost`, `http(s)://tauri.localhost` (or the dev
server in debug builds) gets 403. Range, `Accept-Ranges`, `nosniff`.

### Preview proxies

| Command | Args | Returns | Does |
|---|---|---|---|
| `video_proxy` | `path` | proxy path | an H.264 MP4 copy (≤ 1920 wide, same frames/times) for the preview when the webview can't decode a take: Mac takes are HEVC .mov; WebView2 needs the paid HEVC extension, WebKitGTK needs gst-libav. Made once per file into the app cache; the .reel is untouched and export reads the original |
