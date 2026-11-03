-- Monet Shot on Omarchy 4 (Hyprland Lua config). Loaded from
-- ~/.config/hypr/hyprland.lua by install.sh:
--   dofile("/usr/share/monet-shot/omarchy/hyprland.lua")
-- The app's GTK id is "monet-shot"; its windows are told apart by title.

-- Home and the editors: float (they're sized and placed by the app), like a Mac window.
o.window({ class = "^monet-shot$" }, { float = true })
o.window({ class = "^monet-shot$", title = "^Monet Shot$" }, { center = true })

-- The record pill (3-2-1, time, pause, hold to stop): over everything, on
-- every workspace, top centre under the bar, no animation, never focused,
-- and kept out of screen sharing (Hyprland draws it black there).
o.window({ class = "^monet-shot$", title = "^Monet Shot Pill$" }, {
  pin = true,
  no_anim = true,
  border_size = 0,
  no_shadow = true,
  no_dim = true,
  no_initial_focus = true,
  no_screen_share = true,
  -- The app's own size: Hyprland otherwise maps it at 200x200 (seen on
  -- 0.57), and no_screen_share blacks out the whole window, not just the pill.
  size = { 180, 34 },
  move = { "(monitor_w-window_w)*0.5", 40 },
})
