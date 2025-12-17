package main

// api_window.odin
//
// window.* Lua API (single-window, desktop), backed by raylib.
//
// Intent:
// - Flat, direct mapping to raylib window/cursor calls.
// - No extra state tracked in the engine (mode is derived from raylib state).
// - Fail-fast on wrong argument types (Lua checks); unknown flag/mode tokens raise Lua errors.
//
// opts (init) is a flat array of strings:
//   window.init(w, h, title, { "vsync_on", "resizable", ... })
//
// Supported opts tokens (others are errors):
// - "vsync_on"            -> VSYNC_HINT
// - "fullscreen_mode"     -> FULLSCREEN_MODE
// - "resizable"           -> WINDOW_RESIZABLE
// - "undecorated"         -> WINDOW_UNDECORATED
// - "hidden"              -> WINDOW_HIDDEN
// - "minimized"           -> WINDOW_MINIMIZED
// - "maximized"           -> WINDOW_MAXIMIZED
// - "unfocused"           -> WINDOW_UNFOCUSED
// - "topmost"             -> WINDOW_TOPMOST
// - "mouse_passthrough"   -> WINDOW_MOUSE_PASSTHROUGH
// - "borderless_windowed" -> BORDERLESS_WINDOWED_MODE

import "core:c"
import "core:strings"
import "base:runtime"
import lua "luajit"
import rl  "vendor:raylib"

// -----------------------------------------------------------------------------
// Registration
// -----------------------------------------------------------------------------

// register_window_api creates the global Lua table `window` and installs all functions.
register_window_api :: proc(L: ^lua.State) {
	lua.newtable(L)

	// core
	lua.pushcfunction(L, lua_window_init)     ; lua.setfield(L, -2, cstring("init"))
	lua.pushcfunction(L, lua_window_close)    ; lua.setfield(L, -2, cstring("close"))
	lua.pushcfunction(L, lua_window_maximize) ; lua.setfield(L, -2, cstring("maximize"))
	lua.pushcfunction(L, lua_window_minimize) ; lua.setfield(L, -2, cstring("minimize"))
	lua.pushcfunction(L, lua_window_restore)  ; lua.setfield(L, -2, cstring("restore"))

	// setters
	lua.pushcfunction(L, lua_window_set_title)         ; lua.setfield(L, -2, cstring("set_title"))
	lua.pushcfunction(L, lua_window_set_size)          ; lua.setfield(L, -2, cstring("set_size"))
	lua.pushcfunction(L, lua_window_set_min_size)      ; lua.setfield(L, -2, cstring("set_min_size"))
	lua.pushcfunction(L, lua_window_set_max_size)      ; lua.setfield(L, -2, cstring("set_max_size"))
	lua.pushcfunction(L, lua_window_set_position)      ; lua.setfield(L, -2, cstring("set_position"))
	lua.pushcfunction(L, lua_window_set_fps_limit)     ; lua.setfield(L, -2, cstring("set_fps_limit"))
	lua.pushcfunction(L, lua_window_set_vsync)         ; lua.setfield(L, -2, cstring("set_vsync"))
	lua.pushcfunction(L, lua_window_set_resizable)     ; lua.setfield(L, -2, cstring("set_resizable"))
	lua.pushcfunction(L, lua_window_set_mode)          ; lua.setfield(L, -2, cstring("set_mode"))
	lua.pushcfunction(L, lua_window_set_undecorated)   ; lua.setfield(L, -2, cstring("set_undecorated"))
	lua.pushcfunction(L, lua_window_set_cursor_hidden) ; lua.setfield(L, -2, cstring("set_cursor_hidden"))

	// getters
	lua.pushcfunction(L, lua_window_get_size)     ; lua.setfield(L, -2, cstring("get_size"))
	lua.pushcfunction(L, lua_window_get_position) ; lua.setfield(L, -2, cstring("get_position"))
	lua.pushcfunction(L, lua_window_get_monitor)  ; lua.setfield(L, -2, cstring("get_monitor"))
	lua.pushcfunction(L, lua_window_get_mode)     ; lua.setfield(L, -2, cstring("get_mode"))

	// queries
	lua.pushcfunction(L, lua_window_is_focused)          ; lua.setfield(L, -2, cstring("is_focused"))
	lua.pushcfunction(L, lua_window_is_minimized)        ; lua.setfield(L, -2, cstring("is_minimized"))
	lua.pushcfunction(L, lua_window_is_maximized)        ; lua.setfield(L, -2, cstring("is_maximized"))
	lua.pushcfunction(L, lua_window_is_cursor_hidden)    ; lua.setfield(L, -2, cstring("is_cursor_hidden"))
	lua.pushcfunction(L, lua_window_is_cursor_on_screen) ; lua.setfield(L, -2, cstring("is_cursor_on_screen"))

	push_lua_module(L, cstring("tuicore.window"))
}

// -----------------------------------------------------------------------------
// Init opts -> raylib ConfigFlags
// -----------------------------------------------------------------------------

// window_config_flags_from_opts converts a Lua opts table into raylib ConfigFlags.
// Table shape: { "vsync_on", "resizable", ... } (1-based array part).
window_config_flags_from_opts :: proc "contextless" (L: ^lua.State, idx: c.int) -> rl.ConfigFlags {
	context = runtime.default_context()
	flags := rl.ConfigFlags{}
	tidx := lua.Index(idx)

	// opts is a flat array table: { "vsync_on", "resizable", ... }
	// FAIL-FAST: each element must be a Lua string, or Lua throws.
	n := int(lua.objlen(L, tidx))
	for i in 1..=n {
		lua.rawgeti(L, tidx, lua.Integer(i))

		len: c.size_t
		p := lua.L_checklstring(L, -1, &len)

		// Non-alloc string view for comparisons.
		opt  := strings.string_from_ptr(cast(^u8) p, int(len))


		if opt == "vsync_on" {
			flags |= rl.ConfigFlags{.VSYNC_HINT}
		} else if opt == "fullscreen_mode" {
			flags |= rl.ConfigFlags{.FULLSCREEN_MODE}
		} else if opt == "resizable" {
			flags |= rl.ConfigFlags{.WINDOW_RESIZABLE}
		} else if opt == "undecorated" {
			flags |= rl.ConfigFlags{.WINDOW_UNDECORATED}
		} else if opt == "hidden" {
			flags |= rl.ConfigFlags{.WINDOW_HIDDEN}
		} else if opt == "minimized" {
			flags |= rl.ConfigFlags{.WINDOW_MINIMIZED}
		} else if opt == "maximized" {
			flags |= rl.ConfigFlags{.WINDOW_MAXIMIZED}
		} else if opt == "unfocused" {
			flags |= rl.ConfigFlags{.WINDOW_UNFOCUSED}
		} else if opt == "topmost" {
			flags |= rl.ConfigFlags{.WINDOW_TOPMOST}
		} else if opt == "mouse_passthrough" {
			flags |= rl.ConfigFlags{.WINDOW_MOUSE_PASSTHROUGH}
		} else if opt == "borderless_windowed" {
			flags |= rl.ConfigFlags{.BORDERLESS_WINDOWED_MODE}
		} else {
			// fail-fast on typos
			lua.L_error(L, cstring("window.init: unknown opt '%.*s'"), int(len), p)
		}

		lua.pop(L, 1)
	}

	return flags
}

// -----------------------------------------------------------------------------
// Core
// -----------------------------------------------------------------------------

// window.init(w, h, title, opts?) -> creates the window (opts applied via SetConfigFlags before InitWindow).
lua_window_init :: proc "c" (L: ^lua.State) -> c.int {
	w := c.int(int(lua.L_checkinteger(L, 1)))
	h := c.int(int(lua.L_checkinteger(L, 2)))
	title := lua.L_checklstring(L, 3, nil)

	// Optional opts table at arg 4; if not a table we do nothing.
	if int(lua.gettop(L)) >= 4 && lua.istable(L, 4) {
		rl.SetConfigFlags(window_config_flags_from_opts(L, 4))
	}

	rl.InitWindow(w, h, title)
	return 0
}

// window.close() -> CloseWindow().
lua_window_close :: proc "c" (L: ^lua.State) -> c.int { rl.CloseWindow(); return 0 }
lua_window_maximize :: proc "c" (L: ^lua.State) -> c.int { rl.MaximizeWindow(); return 0 }
lua_window_minimize :: proc "c" (L: ^lua.State) -> c.int { rl.MinimizeWindow(); return 0 }
lua_window_restore  :: proc "c" (L: ^lua.State) -> c.int { rl.RestoreWindow(); return 0 }


//------------------------------------------------------------------------------
// Setters
//------------------------------------------------------------------------------

lua_window_set_title :: proc "c" (L: ^lua.State) -> c.int {
	title := lua.L_checklstring(L, 1, nil)
	rl.SetWindowTitle(title)
	return 0
}


// window.set_title(title) -> SetWindowTitle().
// window.set_size(w, h) -> SetWindowSize().
lua_window_set_size :: proc "c" (L: ^lua.State) -> c.int {
	w := c.int(int(lua.L_checkinteger(L, 1)))
	h := c.int(int(lua.L_checkinteger(L, 2)))
	rl.SetWindowSize(w, h)
	return 0
}

// window.set_min_size(w, h) -> SetWindowMinSize().
lua_window_set_min_size :: proc "c" (L: ^lua.State) -> c.int {
	w := c.int(int(lua.L_checkinteger(L, 1)))
	h := c.int(int(lua.L_checkinteger(L, 2)))
	rl.SetWindowMinSize(w, h)
	return 0
}

// window.set_max_size(w, h) -> SetWindowMaxSize().
lua_window_set_max_size :: proc "c" (L: ^lua.State) -> c.int {
	w := c.int(int(lua.L_checkinteger(L, 1)))
	h := c.int(int(lua.L_checkinteger(L, 2)))
	rl.SetWindowMaxSize(w, h)
	return 0
}

// window.set_position(x, y) -> SetWindowPosition().
lua_window_set_position :: proc "c" (L: ^lua.State) -> c.int {
	x := c.int(int(lua.L_checkinteger(L, 1)))
	y := c.int(int(lua.L_checkinteger(L, 2)))
	rl.SetWindowPosition(x, y)
	return 0
}

// window.set_fps_limit(n) -> SetTargetFPS().
lua_window_set_fps_limit :: proc "c" (L: ^lua.State) -> c.int {
	fps := c.int(int(lua.L_checkinteger(L, 1)))
	rl.SetTargetFPS(fps)
	return 0
}

// window.set_vsync(bool) -> Set/Clear VSYNC_HINT window state.
lua_window_set_vsync :: proc "c" (L: ^lua.State) -> c.int {
	enable := lua.toboolean(L, 1) 
	if enable {
		rl.SetWindowState(rl.ConfigFlags{.VSYNC_HINT})
	} else {
		rl.ClearWindowState(rl.ConfigFlags{.VSYNC_HINT})
	}
	return 0
}

// window.set_resizable(bool) -> Set/Clear WINDOW_RESIZABLE window state.
lua_window_set_resizable :: proc "c" (L: ^lua.State) -> c.int {
	enable := lua.toboolean(L, 1) 
	if enable {
		rl.SetWindowState(rl.ConfigFlags{.WINDOW_RESIZABLE})
	} else {
		rl.ClearWindowState(rl.ConfigFlags{.WINDOW_RESIZABLE})
	}
	return 0
}

// window.set_mode(mode) -> sets exactly one of: "windowed" | "fullscreen" | "borderless_windowed".
lua_window_set_mode :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	mode_len: c.size_t
	mode_c := lua.L_checklstring(L, 1, &mode_len)

	// Non-alloc view for mode token comparisons.
	mode := strings.string_from_ptr(cast(^u8) mode_c, int(mode_len))

	want_windowed   := mode == "windowed"
	want_fullscreen := mode == "fullscreen"
	want_borderless := mode == "borderless_windowed"

	if !want_windowed && !want_fullscreen && !want_borderless {
		return lua.L_error(L, cstring("window.set_mode: unknown mode '%.*s'"), int(mode_len), mode_c)
	}

	is_fullscreen := rl.IsWindowFullscreen()
	is_borderless := rl.IsWindowState(rl.ConfigFlags{.BORDERLESS_WINDOWED_MODE})

	if want_windowed {
		if is_fullscreen { rl.ToggleFullscreen() }
		if is_borderless { rl.ToggleBorderlessWindowed() }
		return 0
	}

	if want_fullscreen {
		if is_borderless { rl.ToggleBorderlessWindowed() }
		if !is_fullscreen { rl.ToggleFullscreen() }
		return 0
	}

	// want_borderless
	if is_fullscreen { rl.ToggleFullscreen() }
	if !is_borderless { rl.ToggleBorderlessWindowed() }
	return 0
}

// window.set_undecorated(bool) -> Set/Clear WINDOW_UNDECORATED window state.
lua_window_set_undecorated :: proc "c" (L: ^lua.State) -> c.int {
	enable := lua.toboolean(L, 1) 
	if enable {
		rl.SetWindowState(rl.ConfigFlags{.WINDOW_UNDECORATED})
	} else {
		rl.ClearWindowState(rl.ConfigFlags{.WINDOW_UNDECORATED})
	}
	return 0
}

// window.set_cursor_hidden(bool) -> HideCursor/ShowCursor.
lua_window_set_cursor_hidden :: proc "c" (L: ^lua.State) -> c.int {
	hide := lua.toboolean(L, 1) 
	if hide {
		rl.HideCursor()
	} else {
		rl.ShowCursor()
	}
	return 0
}

// -----------------------------------------------------------------------------
// Getters
// -----------------------------------------------------------------------------

// window.get_size() -> w, h (GetScreenWidth/Height).
lua_window_get_size :: proc "c" (L: ^lua.State) -> c.int {
	lua.pushinteger(L, lua.Integer(rl.GetScreenWidth()))
	lua.pushinteger(L, lua.Integer(rl.GetScreenHeight()))
	return 2
}

// window.get_position() -> x, y (GetWindowPosition, integer).
lua_window_get_position :: proc "c" (L: ^lua.State) -> c.int {
	pos := rl.GetWindowPosition()
	lua.pushinteger(L, lua.Integer(int(pos.x)))
	lua.pushinteger(L, lua.Integer(int(pos.y)))
	return 2
}

// window.get_monitor() -> idx (GetCurrentMonitor).
lua_window_get_monitor :: proc "c" (L: ^lua.State) -> c.int {
	lua.pushinteger(L, lua.Integer(rl.GetCurrentMonitor()))
	return 1
}

// window.get_mode() -> "windowed" | "fullscreen" | "borderless_windowed" (derived from raylib state).
lua_window_get_mode :: proc "c" (L: ^lua.State) -> c.int {
	if rl.IsWindowFullscreen() {
		lua.pushstring(L, cstring("fullscreen"))
		return 1
	}
	if rl.IsWindowState(rl.ConfigFlags{.BORDERLESS_WINDOWED_MODE}) {
		lua.pushstring(L, cstring("borderless_windowed"))
		return 1
	}
	lua.pushstring(L, cstring("windowed"))
	return 1
}

// -----------------------------------------------------------------------------
// Queries
// -----------------------------------------------------------------------------

// window.is_focused() -> IsWindowFocused().
lua_window_is_focused :: proc "c" (L: ^lua.State) -> c.int {
	lua.pushboolean(L, b32(rl.IsWindowFocused()))
	return 1
}

// window.is_minimized() -> IsWindowMinimized().
lua_window_is_minimized :: proc "c" (L: ^lua.State) -> c.int {
	lua.pushboolean(L, b32(rl.IsWindowMinimized()))
	return 1
}

// window.is_maximized() -> IsWindowMaximized().
lua_window_is_maximized :: proc "c" (L: ^lua.State) -> c.int {
	lua.pushboolean(L, b32(rl.IsWindowMaximized()))
	return 1
}

// window.is_cursor_hidden() -> IsCursorHidden().
lua_window_is_cursor_hidden :: proc "c" (L: ^lua.State) -> c.int {
	lua.pushboolean(L, b32(rl.IsCursorHidden()))
	return 1
}

// window.is_cursor_on_screen() -> IsCursorOnScreen().
lua_window_is_cursor_on_screen :: proc "c" (L: ^lua.State) -> c.int {
	lua.pushboolean(L, b32(rl.IsCursorOnScreen()))
	return 1
}

