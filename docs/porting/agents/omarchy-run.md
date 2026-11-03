# You are ms-omarchy: run the app under real Hyprland

Read `docs/porting/ARCHITECTURE.md`, `docs/PARITY.md` and
`docs/porting/status/*.md` first. The Linux build has run under Xvfb +
openbox in the Arch container (`desktop/tools/run-arch.Dockerfile`,
`linux-run-*.sh`): editor checks 29/29, preview matches the Mac. What has
never run is the Omarchy stack itself: Hyprland, xdg-desktop-portal-hyprland,
PipeWire, the portal ScreenCast recording, Hyprland IPC cursor mapping, the
pill's window rules, and the Omarchy installer on a live session. Your job is
to build that stack in a container, record a real take through it, and fix
what it finds.

## The stack
- Arch container (start from `run-arch.Dockerfile`; the image
  `monetshot-run-arch` and volumes `monetshot-run-target` /
  `monetshot-run-work` already exist, reuse them).
- A headless compositor to host Hyprland: `sway` with
  `WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1`, then Hyprland nested in
  it (aquamarine's Wayland backend). If Hyprland can run headless directly,
  use that instead. Rendering on llvmpipe.
- `pipewire`, `wireplumber`, `xdg-desktop-portal`,
  `xdg-desktop-portal-hyprland`, a dbus session. The share picker can't be
  clicked: set `custom_picker_binary` in `~/.config/hypr/xdph.conf` to a
  script that prints the selection (e.g. `[SELECTION]/screen:<output>`).
- Omarchy's own config: run `desktop/packaging/omarchy/install.sh` against a
  real Omarchy config tree (clone basecamp/omarchy at a 4.x tag, and a 3.x
  tag for the Waybar path), so the binds and window rules are the ones
  users get.

## What to prove, in order
1. **A portal recording.** `MONETSHOT_DEMO_RECORD=1 MONETSHOT_DEMO_STOP=5`
   under Hyprland; the portal dialog is answered by your picker. The take
   has a playing `screen.mp4` showing the Hyprland desktop (put something
   on it: a terminal, a moving window), a `cursor.json` whose coordinates
   come from Hyprland IPC and line up with the picture (move the pointer
   with `hyprctl dispatch movecursor` to known spots and check them), and
   clicks if evdev can be given a device (uinput) in the container; if it
   can't, say so.
2. **The restore token**: a second take skips the picker.
3. **The pill.** While recording, `hyprctl clients -j` shows the pill
   floating, pinned, at the size and place the rules say, and absent from
   the recording. Screenshot it with `grim`.
4. **The bar.** 4.x: the omarchy-shell plugin shows the state from
   `monet-shot status --follow`; 3.x: the Waybar module. Screenshot both if
   they'll run; otherwise check their JSON against a recording in progress.
5. **SUPER+ALT+R** via `hyprctl dispatch` of the installed bind starts and
   stops a take.
6. **Editor + export** on that take (devchecks `editor.js` as the Xvfb run
   did, then an export), under Hyprland this time.

Wrap it in `desktop/tools/hypr-*.sh` and a Dockerfile so it reruns with one
command, and, if it's under ~15 minutes, as a CI job (`hyprland-run`) in
`.github/workflows/desktop.yml`.

## You own
- `desktop/tools/hypr-*`, new Dockerfiles, the `hyprland-run` CI job.
- Fixes in `desktop/crates/capture/src/linux*`, `desktop/packaging/omarchy`,
  and Linux-only paths in `desktop/app/src-tauri`. Shared code: keep it
  small and tell the lead (`stylefeatures-d1`). `ms-win` works on Windows
  in parallel and also edits `desktop.yml`: pull before you push, and touch
  only your own job.

## Rules
- Commit only your files. End commit messages with `Co-Authored-By: Claude
  Opus 5.5 <noreply@anthropic.com>`. `git pull --rebase` before pushing.
  Push to `desktop-port` only: no PRs, no merges, no releases.
- Never touch `Sources/`, `Resources/Music/` or anything uncommitted that
  isn't yours (Connor's Mac work in progress).
- Disk on this Mac is tight (~14 GB). One container at a time, build inside
  the existing target volume, and remove images you create and stop needing.
  If free space drops under 5 GB, stop and tell the lead.
- When done, update the Omarchy column in `docs/PARITY.md` (mark what ran
  "Hyprland in a container", not ✅, since that isn't real hardware), write
  `docs/porting/status/omarchy-run.md`, and message the lead.
