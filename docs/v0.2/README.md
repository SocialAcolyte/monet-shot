# Monet Shot 0.2: vertical, music, captions

Connor asked for three things, on the Mac app and the Windows/Linux app alike,
then a release to everyone:

1. **Vertical**: videos for phones (9:16: Reels, Shorts, TikTok, a phone
   screen), not a 16:9 screen shrunk into a tall frame. Brief: `vertical.md`.
2. **Better music selection**. Brief: `music.md`.
3. **Transcription**: speech to text, shown as captions in the video and saved
   as subtitles. Brief: `captions.md`.

Three agents, one per feature, each in its own git worktree and branch. The
lead (Claude, the session that briefed you) merges the three branches into
`v0.2`, bumps the version to 0.2.0, installs the Mac app on Connor's Mac and
publishes the release.

## Read first
- `docs/porting/ARCHITECTURE.md`, `docs/PARITY.md` (the parity contract: the
  edit.json format is shared, Swift golden fixtures in `shared/fixtures` drive
  the Rust tests, and the ledger at the bottom lists every feature by platform)
- `docs/spec.md`, `README.md`
- `docs/porting/status/*.md`: how the desktop app is built, run and
  screenshotted on CI (windows-run on the Windows VM, hyprland-run for Linux)
- The commit `2811c92` (clip speed, text overlays, formats): the most recent
  feature built on both sides at once. Copy how it was done: model in both
  Kits, fixtures, inspector on both sides, PARITY rows, README lines.

## Layout
- Mac: Swift, `Sources/MonetShotKit` (model, render), `Sources/MonetShot`
  (app, editor UI), `Sources/MonetShotChecks` (headless checks:
  `swift run MonetShotChecks`). Snapshots of the UI via the `MONETSHOT_SNAPSHOT*`
  env vars (README / spec); Claude has no screen capture here.
- Desktop: `desktop/` Tauri 2: Rust crates in `desktop/crates` (core, export,
  capture, core-wasm), Svelte UI in `desktop/app/ui`.
- Fixtures: `shared/tools/fixtures.sh` regenerates them from the Swift Kit; CI
  fails if they differ from what's committed.

## Rules (all three agents)
- Work only in your worktree, on your branch. Push your branch as often as
  you like: CI (`.github/workflows/desktop.yml`) runs on every push and builds
  + tests the Mac app, Linux (AppImage/deb), Arch and Windows, and runs the
  app on the Windows VM. `hyprland.yml` runs on desktop changes. Use
  `gh run list -b <branch>` / `gh run view --log-failed` to read them.
  **Every feature must be green on CI before you report done.**
- **Disk is nearly full (~6 GB free).** Never `tauri build` locally, never
  Docker. Locally: `swift build`, `swift run MonetShotChecks`, and
  `cargo test -p <crate>` with
  `CARGO_TARGET_DIR=$HOME/Developer/monetshot/desktop/target` (shared by all
  three agents; don't `cargo clean` it). Run `df -h ~` now and then; below
  2 GB, stop and tell the lead. Keep scratch files inside your worktree
  (e.g. `scratch/`, gitignored), never in /tmp.
- Don't touch another agent's area beyond the small shared seams named in
  your brief. Expect merge conflicts in `Project.swift`, `model.rs`, the
  inspectors and PARITY.md; keep your changes there small and self-contained
  (new files where possible) so the lead's merge is easy.
- No version bump, no releases, no tags, no pushing `main` or `v0.2`, no
  Homebrew tap: the lead does those.
- Commits as the repo's existing author (SocialAcolyte noreply, already in
  git config), ending with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Connor's taste: elegant, calm, few words, the app's existing Insomnia-like
  style. No placeholder UI, no buttons that do nothing.
- When done: write `docs/v0.2/status/<you>.md` (what was built, how it was
  proven on each platform, what's not proven, screenshots' paths) and finish
  with a short report: branch, last green CI run URL, anything the lead must
  know to merge.
