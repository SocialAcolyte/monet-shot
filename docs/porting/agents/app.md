# You are ms-app: the app people see

Read `docs/porting/ARCHITECTURE.md` and `docs/PARITY.md` first. You own
`desktop/app/` (src-tauri + ui) and `docs/porting/contracts/ipc.md`.

Reference: everything in `Sources/MonetShot/` (App, UI, Home, Editor, Music)
and the README's "Use it" section. Match the Insomnia look and Connor's
taste: copy colours, type, spacing, motion from the Swift views; no
invented chrome. Behaviour (keys, gestures, hold-to-stop, undo) must match.

## Order

1. **Scaffold** Tauri 2 + Svelte 5 + TS + Vite in `desktop/app`, add
   `app/src-tauri` to the workspace members in `desktop/Cargo.toml` (the
   only line you touch there). Runs on this Mac (`cargo tauri dev`) with the
   capture crate's macos-dev backend, so you can see everything you build.
   Bundle resources from `../../Resources` (Backdrops, icon), not copies.
2. **Tray + pill**: tray icon rendered per state (idle ring, countdown,
   clay ring + time) since Linux/Windows trays have no text; right-click
   menu (Open Monet Shot, Record My Camera Too, picker choice, Quit); a small
   always-on-top pill window for 3-2-1, time, pause, press-and-hold stop.
   Write `docs/porting/contracts/ipc.md` as you add commands/events.
3. **Home**: cards rendered with their backdrop, import video, reveal in
   file manager, move to trash (`trash` crate).
4. **Editor**: preview painter in WebGL2 driven by the FramePlan from
   `core-wasm` (ms-core writes `docs/porting/contracts/frame-plan.md`; start
   on the layout/timeline while it lands), `<video>` per take as sources;
   transport, timeline (clips filmstrips, zoom lane, camera lane, hatched
   cuts, drag/resize/split/move/delete, drop videos), inspector (all Mac
   controls), backdrop gallery (20 paintings + own image + blur), framing
   mode (Hide boxes + Crop, B/R/Esc), camera overlay + recording over the
   edit, music browser, export with progress (calls the export crate), undo/redo,
   all keyboard shortcuts.
5. Check it on WebKitGTK too: the Linux webview is WebKit, not Chromium.
   Avoid APIs WebKitGTK lacks; test the UI in Safari (closest engine on this
   Mac) as well as the Tauri window.

Keep `docs/porting/status/app.md` current. Don't commit. Tell the lead
(`stylefeatures-d1`) when each numbered step is done.
