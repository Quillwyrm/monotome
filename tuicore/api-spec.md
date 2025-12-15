...// window.* — Lua C-callable procs (Odin)
// From spec: :contentReference[oaicite:0]{index=0}

//
// Core
//
lua_window_init      :: proc(L: ^lua.State) -> int
lua_window_close     :: proc(L: ^lua.State) -> int
lua_window_maximize  :: proc(L: ^lua.State) -> int
lua_window_minimize  :: proc(L: ^lua.State) -> int
lua_window_restore   :: proc(L: ^lua.State) -> int

//
// Setters
//
lua_window_set_title         :: proc(L: ^lua.State) -> int
lua_window_set_size          :: proc(L: ^lua.State) -> int
lua_window_set_min_size      :: proc(L: ^lua.State) -> int
lua_window_set_max_size      :: proc(L: ^lua.State) -> int
lua_window_set_position      :: proc(L: ^lua.State) -> int
lua_window_set_fps_limit     :: proc(L: ^lua.State) -> int
lua_window_set_vsync         :: proc(L: ^lua.State) -> int
lua_window_set_resizable     :: proc(L: ^lua.State) -> int
lua_window_set_mode          :: proc(L: ^lua.State) -> int
lua_window_set_undecorated   :: proc(L: ^lua.State) -> int
lua_window_set_cursor_hidden :: proc(L: ^lua.State) -> int

//
// Getters
//
lua_window_get_size      :: proc(L: ^lua.State) -> int
lua_window_get_position  :: proc(L: ^lua.State) -> int
lua_window_get_monitor   :: proc(L: ^lua.State) -> int
lua_window_get_mode      :: proc(L: ^lua.State) -> int

//
// Queries
//
lua_window_is_focused          :: proc(L: ^lua.State) -> int
lua_window_is_minimized        :: proc(L: ^lua.State) -> int
lua_window_is_maximized        :: proc(L: ^lua.State) -> int
lua_window_is_cursor_hidden    :: proc(L: ^lua.State) -> int
lua_window_is_cursor_on_screen :: proc(L: ^lua.State) -> int
package tuicore











# `window.*` — Window API (Lua)

## Overview

Single-window, desktop-only API backed by raylib window + cursor functions.

* Init-time options map to `SetConfigFlags(...)` (applied before window creation)
* Runtime setters map to `SetWindow*`, `Toggle*`, and `SetTargetFPS`
* Min/max size only applies when the window is resizable (`FLAG_WINDOW_RESIZABLE`)

---

## Core

* `init(w, h, title, opts?)`
  Create the window and graphics context (`InitWindow`).

  * `opts` is optional and **init-only** (applied via `SetConfigFlags(...)` before `InitWindow`).
  * `opts` is a flat list of flag strings.

  Supported `opts` flags:

  * `"vsync_on"`
  * `"fullscreen_mode"`
  * `"resizable"`
  * `"undecorated"`
  * `"hidden"`
  * `"minimized"`
  * `"maximized"`
  * `"unfocused"`
  * `"topmost"`
  * `"mouse_passthrough"`
  * `"borderless_windowed"`

* `close()`
  Destroy window and graphics context (`CloseWindow`).

* `maximize()`
  Maximize the window (`MaximizeWindow`).

  * Only meaningful when resizable.

* `minimize()`
  Minimize/iconify the window (`MinimizeWindow`).

  * Only meaningful when resizable.

* `restore()`
  Restore from minimized or maximized state (`RestoreWindow`).

---

## Setters

* `set_title(title)`
  Set window title (`SetWindowTitle`).

* `set_size(w, h)`
  Set window dimensions (`SetWindowSize`).

* `set_min_size(w, h)`
  Set minimum resize bounds (`SetWindowMinSize`).

  * Only meaningful when resizable.

* `set_max_size(w, h)`
  Set maximum resize bounds (`SetWindowMaxSize`).

  * Only meaningful when resizable.

* `set_position(x, y)`
  Move window on screen (`SetWindowPosition`).

* `set_fps_limit(n)`
  Set target FPS cap (`SetTargetFPS`).

* `set_vsync(bool)`
  Enable/disable vsync via raylib window state / config flags.

* `set_resizable(bool)`
  Enable/disable window resizing (window state flag).

* `set_mode(mode)`
  Set **exactly one** window mode:

  * `"windowed"`
  * `"fullscreen"` — raylib fullscreen toggle (monitor resolution is changed)
  * `"borderless_windowed"` — raylib borderless-windowed toggle (window resizes to monitor)

* `set_undecorated(bool)`
  Enable/disable window decorations (frame/buttons).

  * Contract: only meaningful in `"windowed"` mode (ignored or auto-cleared in other modes).

* `set_cursor_hidden(bool)`
  Show or hide the OS cursor (`ShowCursor` / `HideCursor`).

---

## Getters

* `get_size() -> w, h`
  Current window size (`GetScreenWidth`, `GetScreenHeight`).

* `get_position() -> x, y`
  Window position in the coordinate space of its current monitor (`GetWindowPosition`).

* `get_monitor() -> idx`
  Current monitor index (`GetCurrentMonitor`).

* `get_mode() -> mode`
  Current window mode (`"windowed" | "fullscreen" | "borderless_windowed"`).

  * Authoritative engine-tracked state.

---

## Queries

* `is_focused()`
  Window has OS focus (`IsWindowFocused`).

* `is_minimized()`
  Window is minimized (`IsWindowMinimized`).

* `is_maximized()`
  Window is maximized (`IsWindowMaximized`).

* `is_cursor_hidden()`
  Cursor is currently hidden (`IsCursorHidden`).

* `is_cursor_on_screen()`
  Cursor is within window bounds (`IsCursorOnScreen`).

---

## Notes

* `set_min_size` / `set_max_size` have no effect unless the window is resizable.
* `"borderless_windowed"` is a distinct raylib mode, not the same as `"undecorated"`. 

