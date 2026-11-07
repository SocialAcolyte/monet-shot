# You are ms-welcome: something happens after you install it

Connor sent a friend the Windows build. Even once it's installed, a
non-technical person sees nothing: Monet Shot starts as a tray icon, and on
Windows 11 that's hidden under the ^ arrow. On Linux it's a terminal job.
Your job is what a person sees between "installed" and "first recording", on
Windows and Linux, plus a one-line Linux install.

Read first: `docs/porting/ARCHITECTURE.md`, `docs/PARITY.md`,
`docs/porting/status/*.md` (windows-run.md and omarchy-run.md show how the
app is run and screenshotted on CI), and the Svelte UI in `desktop/app/ui`.

## What to build
1. **A welcome window on first launch** (Windows and Linux; the Mac app is
   Swift and off limits, so record the gap in PARITY's Mac column as "to
   do"). Small, calm, in the app's own style (its editor and Home screen:
   same type, colours, the Great Wave icon). It says, in very few words:
   - where Monet Shot lives now: on Windows an arrow towards the tray corner,
     with "click ^ if you don't see it" and a one-click way to pin it
     (open Settings › Personalization › Taskbar › Other system tray icons, or
     whatever Windows 11 allows); on Omarchy the bar widget and SUPER+ALT+R;
     on other Linux the tray;
   - a big **Record your first take** button that starts the normal flow;
   - a "Start Monet Shot when I log in" toggle (tauri-plugin-autostart),
     off by default.
   It shows on the first launch only (a flag in the app's settings), and
   again if the app is launched while already running (a second launch from
   the Start menu must do something visible: show Home or this window, never
   nothing).
2. **Linux one-liner.** `desktop/packaging/install.sh`, to be served at
   `https://monetshot.pages.dev/install.sh`, so a Linux person pastes one
   line: `curl -fsSL https://monetshot.pages.dev/install.sh | bash`. It
   detects the system and downloads from
   `https://github.com/SocialAcolyte/monet-shot/releases/latest/download/`
   (names below): Arch/Omarchy → `monet-shot-x86_64.pkg.tar.zst` with
   `sudo pacman -U`, then `monet-shot-omarchy` on Omarchy; Debian/Ubuntu →
   `monet-shot_amd64.deb` with `sudo apt install ./…`; anything else →
   `MonetShot-Linux.AppImage` into `~/.local/bin` with a `.desktop` entry
   and icon so it's in the app menu. Checks sha256 against `SHA256SUMS`,
   says what it's doing in plain words, asks before sudo. `--uninstall`.
   Also an AUR `monet-shot-bin` PKGBUILD in `desktop/packaging/aur/` (Connor
   publishes it; you don't).
   Asset names: `MonetShot-Linux.AppImage`, `monet-shot_amd64.deb`,
   `monet-shot-x86_64.pkg.tar.zst`, `SHA256SUMS` (ms-release owns them;
   until its release exists, test with a `MONETSHOT_BASE_URL` override
   pointed at the `desktop-v0.1.1` release's files).

## Proving it
- Windows: add a windows-run stage: fresh home, launch → the welcome window
  is up (screenshot it), the Record button reaches the picker, a second
  launch brings a window forward, the autostart toggle writes the Run key and
  clears it.
- Linux: the same under hyprland-run (screenshot under Omarchy's theme), and
  install.sh run in CI containers for archlinux, ubuntu and fedora (a new
  small job in hyprland.yml or its own workflow), each ending with the app's
  `--version`.

## You own
`desktop/app/ui` (welcome), first-run and autostart code in
`desktop/app/src-tauri/src` (keep shared changes small; say what in your
status), `desktop/packaging/install.sh`, `desktop/packaging/aur/`, the new
CI stages. ms-release owns `tauri.conf.json`'s `bundle` section and
`release.yml`; adding the autostart plugin to `plugins` is yours: pull before
you push.

## Rules
- Push to `desktop-port` only. No releases, no AUR push, no merge to main.
- Never touch `Sources/`, `Resources/Music/` or anything uncommitted that
  isn't yours.
- Disk on this Mac is ~12 GB free: test in CI, not local Docker.
- `git pull --rebase` before pushing. End commits with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- When done: `docs/porting/status/welcome.md`, PARITY rows, and message the
  lead (`stylefeatures-7c`) with screenshots' paths.
