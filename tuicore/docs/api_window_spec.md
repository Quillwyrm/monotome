# `window.*` spec (Lua surface)

Backed by `api_window.odin` (raylib single-window + cursor). 

## Overview

* `window` is a global table created by `register_window_api(L)`. 
* `init(..., opts?)` accepts an optional **flat array** of flag strings: `{ "vsync_on", "resizable", ... }`. 
* Unknown flag strings and unknown mode strings are **ignored** (no-op). 
* Each `opts[i]` must be a Lua string (fail-fast via `L_checklstring`). 
* Mode is **derived from raylib state** (no engine-tracked mode variable).  

---

## Core

* `init(w, h, title, opts?)`
  Create the window (`rl.InitWindow`). If `opts` is present and is a table, applies flags via `rl.SetConfigFlags(...)` **before** init. 

  Supported `opts` strings (others ignored): 

  * `"vsync_on"` → `VSYNC_HINT`
  * `"fullscreen_mode"` → `FULLSCREEN_MODE`
  * `"resizable"` → `WINDOW_RESIZABLE`
  * `"undecorated"` → `WINDOW_UNDECORATED`
  * `"hidden"` → `WINDOW_HIDDEN`
  * `"minimized"` → `WINDOW_MINIMIZED`
  * `"maximized"` → `WINDOW_MAXIMIZED`
  * `"unfocused"` → `WINDOW_UNFOCUSED`
  * `"topmost"` → `WINDOW_TOPMOST`
  * `"mouse_passthrough"` → `WINDOW_MOUSE_PASSTHROUGH`
  * `"borderless_windowed"` → `BORDERLESS_WINDOWED_MODE`

* `close()`
  Destroy window (`rl.CloseWindow`). 

* `maximize()`
  Maximize (`rl.MaximizeWindow`). 

* `minimize()`
  Minimize/iconify (`rl.MinimizeWindow`). 

* `restore()`
  Restore (`rl.RestoreWindow`). 

---

## Setters

(All “bool” params use Lua truthiness via `lua.toboolean`.) 

* `set_title(title)`
  `rl.SetWindowTitle`. 

* `set_size(w, h)`
  `rl.SetWindowSize`. 

* `set_min_size(w, h)`
  `rl.SetWindowMinSize`. 

* `set_max_size(w, h)`
  `rl.SetWindowMaxSize`. 

* `set_position(x, y)`
  `rl.SetWindowPosition`. 

* `set_fps_limit(n)`
  `rl.SetTargetFPS`. 

* `set_vsync(bool)`
  Sets/clears `VSYNC_HINT` window state. 

* `set_resizable(bool)`
  Sets/clears `WINDOW_RESIZABLE` window state. 

* `set_mode(mode)`
  Normalizes raylib’s toggle API into a “set exactly this mode” call. Unknown strings ignored. 
  Accepted strings:

  * `"windowed"`
  * `"fullscreen"`
  * `"borderless_windowed"`

* `set_undecorated(bool)`
  Sets/clears `WINDOW_UNDECORATED` window state. (No extra mode coupling; it does not auto-clear in fullscreen/borderless.) 

* `set_cursor_hidden(bool)`
  `rl.HideCursor` / `rl.ShowCursor`. 

---

## Getters

* `get_size() -> w, h`
  `rl.GetScreenWidth`, `rl.GetScreenHeight`. 

* `get_position() -> x, y`
  `rl.GetWindowPosition` (converted to integers). 

* `get_monitor() -> idx`
  `rl.GetCurrentMonitor`. 

* `get_mode() -> mode_string`
  Derived from raylib state (no engine-tracked state): 

  * if fullscreen → `"fullscreen"`
  * else if borderless flag → `"borderless_windowed"`
  * else → `"windowed"`

---

## Queries

* `is_focused() -> bool`
  `rl.IsWindowFocused`. 

* `is_minimized() -> bool`
  `rl.IsWindowMinimized`. 

* `is_maximized() -> bool`
  `rl.IsWindowMaximized`. 

* `is_cursor_hidden() -> bool`
  `rl.IsCursorHidden`. 

* `is_cursor_on_screen() -> bool`
  `rl.IsCursorOnScreen`. 

