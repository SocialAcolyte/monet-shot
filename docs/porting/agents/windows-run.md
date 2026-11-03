# You are ms-win: run the Windows build on real Windows

Read `docs/porting/ARCHITECTURE.md`, `docs/PARITY.md` and
`docs/porting/status/*.md` first. The Windows port compiles, its tests pass
on GitHub's `windows-latest`, and the NSIS installer builds, but nothing has
ever *run* the app there: no WebView2 window, no Windows.Graphics.Capture
recording, no export. Your job is to make CI do that, on every push, and to
fix what it finds.

There is no Windows machine here. GitHub's Windows runner is a real Windows
Server VM with an interactive desktop and WebView2, so it's your hardware.
Work through CI: push to `desktop-port`, read the run with `gh run view
--log-failed` / `gh run download`, fix, repeat.

## You own
- A new job `windows-run` in `.github/workflows/desktop.yml` (needs:
  `windows`, or builds its own debug binary; keep the existing jobs green).
- `desktop/tools/windows-*.{sh,ps1}` helpers you add.
- Fixes in `desktop/crates/capture/src/windows*` and Windows-only code paths
  in `desktop/app/src-tauri`. Shared code: keep the change small, and tell
  the lead (`stylefeatures-d1`) what you changed and why.

## What the job proves, in order
1. **The app starts and records.** The release exe with
   `MONETSHOT_HOME=<temp> MONETSHOT_DEMO_RECORD=1 MONETSHOT_DEMO_STOP=5`
   (hooks in `bar.rs`, `recorder.rs`: clicks the ring, records the first
   display, stops after 5 s). Check the take folder: `screen.mp4` plays
   (ffprobe: duration ~5 s, frames > 0), `cursor.json` has samples,
   `meta.json` parses as the Mac's format (core's `Project` loader). Move the
   mouse and click during the take (PowerShell `SendInput` / `SetCursorPos`)
   so cursor and click logs have something real in them.
2. **The editor runs in WebView2.** A debug build (it loads the Vite dev
   server, so `npm run dev` in the background) opened on a *copy* of that
   take with `MONETSHOT_DEV_SCRIPT=<abs path>/desktop/app/ui/devchecks/editor.js`.
   Pass = the log (`core::paths::log_file()`) ends with `check: done N ok, 0
   failed`. Mind Windows paths in `/@fs${devscript}` (main.ts): a
   `C:\...` path needs turning into `/C:/...`.
3. **The preview matches the Mac.** `MONETSHOT_DEV_PAGE=fixtures-test.html`
   in the same debug build; every `fixtures:` line within the tolerance the
   Linux run met (mean ≤ 1/255).
4. **The H.264 proxy.** Open a Mac HEVC take from `shared/fixtures` (or one
   the job makes with ffmpeg `-c:v libx265`) and confirm the editor falls
   back to `media::video_proxy` and plays.
5. **Export.** Export the recorded take to MP4 (find the command/entry the
   app uses; a small test-only entry point is fine) and ffprobe the result.
6. Upload as an artifact: the app log, the take, the export, and a desktop
   screenshot taken while the editor is open
   (`[System.Windows.Forms.Screen]` + `Graphics.CopyFromScreen`).

Fail the job on any of 1–5. Don't use `continue-on-error`.

## Rules
- Commit only your files, as the repo's existing author config. End commit
  messages with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
  Pull with `git pull --rebase` before you push. Push to `desktop-port`
  only: no PRs, no merges to main, no releases.
- Never touch `Sources/`, `Resources/Music/` or anything uncommitted that
  isn't yours (that's Connor's Mac work in progress).
- Disk on this Mac is tight (~14 GB). Don't build Windows targets locally
  beyond `cargo check`; let CI build.
- When done, update the Windows column in `docs/PARITY.md` (✅ only for what
  the job actually ran; say "CI VM" next to it), write
  `docs/porting/status/windows-run.md`, and message the lead.
