# ms-omarchy status: the Linux build under real Hyprland (Omarchy)

**Where it runs.** The `hyprland-run` job in `.github/workflows/hyprland.yml`
runs on GitHub's `ubuntu-latest` (kernel 7.0.0-azure, x86_64). It has its own
workflow, so it neither waits for nor holds up `desktop` and its 25 min
windows-run.
- `modprobe vkms` gives `/dev/dri/card1`, a virtual KMS display.
  linux-modules-extra was already installed. uinput gives a virtual mouse and
  keyboard.
- An Arch container (`desktop/tools/hypr-arch.Dockerfile`, built on
  `run-arch.Dockerfile`) runs Hyprland 0.57.0 on its own **DRM backend** on
  that card, rendering with Mesa llvmpipe. seatd provides the seat and
  systemd-udevd tags the devices. Then come PipeWire + WirePlumber,
  xdg-desktop-portal + xdg-desktop-portal-hyprland, and **Omarchy's own config
  trees**: basecamp/omarchy at **v4.0.6** (Lua Hyprland, omarchy-shell) and
  **v3.8.4** (hyprlang, Waybar). The display is 1600x900@60 at scale 1.
- Re-run with `desktop/tools/hypr-run.sh` on any Linux host with vkms
  (`KEEP=1` keeps the container). It runs `hypr-kmod.sh` (modprobe),
  `hypr-build.sh` (wasm + dev app + Vite), `hypr-session.sh start 4` and
  `hypr-check.sh all`.
- Results, screenshots, cursor logs, bar feeds and every log land in the
  `hyprland-run` artifact (`results.txt` first).
- **Time:** 8–10 min with the cargo cache (images 3 min, build under 1,
  checks about 4), about 20 min cold. That's under the brief's 15 min, so the job
  runs on every push that touches `desktop/`, `shared/`,
  `Resources/Backdrops/` or the workflow.

Docker Desktop on the Mac can't do this; the vkms step is Docker-Desktop-specific
in that sense. LinuxKit's kernel (6.12.5-linuxkit) has no vkms. A vkms.ko built
from vanilla 6.12.5 with its own config and its compiler (Alpine gcc 13.2.1)
loads up to the symbol check, then is refused: "disagrees about version of
symbol module_layout". LinuxKit's tree is patched, and Docker publishes no
headers/Module.symvers for it (`docker/for-desktop-kernel` stops at 6.4.2,
`linuxkit/kernel` has no 6.12.5). There's no `/dev/kvm` for a VM either.
Hyprland needs a DRM fd for its allocator, so its headless backend and
llvmpipe alone aren't enough. Nothing was left loaded in Docker's VM; both
insmods were refused.

## Done: 45 ok, 0 failed (run 41659841471, 2026-11-03)

Screens, `results.txt` and a bar feed from that run are in
`docs/porting/screens/omarchy/`.

"Hyprland in a container" means this job; it isn't real hardware.

1. **Session.** Hyprland starts on vkms with Omarchy 4's config and no
   config errors. omarchy-shell answers its IPC; the bar reserves 26 px.
2. **install.sh on the live session** (Omarchy 4):
   - It adds the window rules (`dofile` in hyprland.lua) and SUPER+ALT+R
     (bindings.lua). Hyprland lists the bind: modmask 72, R, "Monet Shot:
     record or stop".
   - The omarchy-shell plugin validates, is enabled, and sits after the
     clock (`listPlugins`).
3. **Portal recording** (`MONETSHOT_DEMO_RECORD=1`, stop after 7–8 s): the
   ScreenCast portal is answered by xdph's `custom_picker_binary`
   (`hypr-picker.sh`, `[SELECTION]r/screen:Virtual-1`).
   - `screen.mp4` is H.264 1600x900 at 60 fps; 486 frames for 8.1 s decode.
   - It shows the desktop: a ticking clock terminal, and the "mover" window
     slid across.
4. **cursor.json from Hyprland IPC.** The pointer goes to six known points
   (`hl.dsp.cursor.move`), and each shows up in order.
   - In the frame at the first point, the mover window's corner (its
     magenta inside) is at exactly the logged point: off by 0,0 on all four
     takes.
   - A uinput click (ydotool) through evdev is logged at the last point.
5. **Restore token.** The second take never asks the picker (0 calls; the
   first take asked once), and the takes after it don't either.
6. **SUPER+ALT+R** is pressed as real keys on the uinput keyboard (Hyprland
   lists ydotoold's keyboard): one press starts a take, a second stops it,
   and the take is saved. A Lua bind's function can't be dispatched from
   hyprctl, so keys are the honest test.
7. **Editor + export** (`devchecks/editor.js` on a copy of take 1, dev app on
   Vite, WebKitGTK): 27 ok, 0 failed. The export is H.264 1920x1080, 5.7 s,
   36 s to make.
8. **Home + clips** (`devchecks/home.js`, a library of "Open me" and "Trash
   me"): all checks ok.
   - Move to Trash puts the reel in `~/.local/share/Trash/files`.
   - Show in folder hands the folder to the file manager (xdg-open, after
     the fix below).
   - Record a new take from the editor goes through the portal again (the
     picker is asked; a new home has no token), and its clips arrive
     (`take-3`). Reorder, undo and save also pass.
9. **The bar**, fed by `monet-shot status --waybar --follow` and logged per
   take (`*-bar.jsonl`): idle → picking → countdown 3, 2, 1 → recording
   0:00…0:07 → idle.
   - **Omarchy 4:** the omarchy-shell plugin shows "● 0:04" in the theme's
     red beside the clock (`*-bar-zoom.png`).
   - **Omarchy 3:** install.sh (against a 3.8.4 home) adds
     `custom/monet-shot` after the screen-recording indicator. That Waybar,
     run in the live session, shows "● 0:05" in the Mac app's clay while
     recording (`waybar-bar-zoom.png` vs the shipped bar in
     `waybar-before-zoom.png`). Its own follower saw idle → countdown →
     recording → saving → idle.
10. **The pill.** `hyprctl clients` during the 3-2-1 shows it floating and
    pinned, 180x34 at 710,40: the rule's size, centred, y 40.
    - With a bar showing our status (Omarchy), the pill isn't mapped while
      recording, so it's not in the take.
    - With no bar it stays up, and `no_screen_share` makes it a black
      180x34 box in the take (Hyprland's way; mean luma 0/255 there).
    - grim is a screencopy client too, so the pill's shot
      (`o4-take1-countdown-pill.png`, "◉ 3") lifts the prop for one frame.
11. **Pause** by double-tap Shift on the uinput keyboard: the status goes to
    paused, a second double-tap resumes, and the bar shows the pause icon.

## Found and fixed
- `packaging/omarchy/plugin/manifest.json`: `defaultSection: "centerEnd"` is
  refused by `omarchy-plugin-validate` (left/center/right only). It's now
  `center`.
- `packaging/omarchy/install.sh`:
  - It enables the plugin through the shell (`rescanPlugins`, then
    `omarchy-plugin-enable --section center --after omarchy.clock`).
  - It retries, because the shell rescans asynchronously, and says why when
    it can't.
- `packaging/omarchy/plugin/Widget.qml`: `BarIconButton` is fixed to the
  icon slot, so "● 0:05" overflowed onto the clock and the next widget. With
  a label it's now a `WidgetButton` sized to the text.
- `app/src-tauri/src/commands.rs` (`reveal`, Linux-only block): without an
  `org.freedesktop.FileManager1` service, tauri-plugin-opener 2.7.2 falls
  back to the OpenURI portal with the bus name and interface swapped, so it
  always failed. We now open the folder (xdg-open) when the reveal fails.
  Omarchy normally has Nautilus, but any setup without FileManager1 hit it.
- **The pill mapped at 200x200**, not 180x34. WAYLAND_DEBUG showed GTK
  sending `set_min_size(200,200)`/`set_max_size(200,200)`: a non-resizable
  GTK3 window takes its child's natural size, ignoring `inner_size`/`set_size`.
  ms-win made it resizable on Linux (windows.rs, 8f6e711; my first
  suggestion had the condition inverted, 18e650c). The rules also give it
  `size = {180, 34}`, because `no_screen_share` blacks out the whole window:
  a 200x200 black square in a take made without a bar module.
- `packaging/omarchy/waybar-module.jsonc`: `restart-interval: 5`. Waybar
  doesn't restart a continuous `exec` that ends, so a follower killed by
  an upgrade or crash froze the module. The harness caught it by killing
  every `monet-shot` between takes. The omarchy-shell widget already
  retries.
- `hyprland.yml` / `desktop.yml`: `desktop.yml` is now `cancel-in-progress:
  false` (the lead's call), and hyprland-run has its own workflow.

## Open
- Nothing known. The camera bubble got the same resizable change (ms-win,
  bc6fe26), but it isn't checked here (no camera on the runner).

## Not proved by this job
- Omarchy 3.x as a whole session. Hyprland 0.57 (Arch's today) reads only
  Lua; a hyprlang config is parsed as Lua and fails. So 3.x is tested as its
  install.sh + Waybar inside the 4.x session, not as Omarchy 3's own
  Hyprland config. Omarchy 3 users on Hyprland ≤0.52 aren't covered.
- Real hardware: GPUs, HiDPI scales (the session is scale 1; Omarchy's
  GDK_SCALE=2 isn't set for the app here), multiple monitors, real
  keyboards and mice (all input is uinput).
- The share picker UI (a script answers it), the PKGBUILD install path (the
  app runs from the build tree, and install.sh from the checkout), the tray
  icon, camera, music, window (not display) recording.
- Clicking the bar widget itself (the commands it runs are what the bind
  and `toggle` run).
