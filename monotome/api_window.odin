package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import lua "luajit"
import sdl "vendor:sdl3"

//========================================================================================================================================
// WINDOW API 
// Lua exposed API for handling sdl windowing (monotome.window.*)
//========================================================================================================================================

// read_window_flags parses {"fullscreen","borderless","resizable"} into three booleans.
read_window_flags :: proc(L: ^lua.State, idx: lua.Index) -> (fullscreen, borderless, resizable: bool) {
	lua.L_checktype(L, cast(c.int)(idx), lua.Type.TABLE)

	i: lua.Integer = 1
	for {
		lua.rawgeti(L, idx, i) // push flags[i]

		t := lua.type(L, -1)
		if t == lua.Type.NIL {
			lua.pop(L, 1)
			break
		}

		len: c.size_t
		p := lua.L_checklstring(L, -1, &len)
		s := strings.string_from_ptr(cast(^u8)(p), int(len))

		if s == "fullscreen" {
			fullscreen = true
		} else if s == "borderless" {
			borderless = true
		} else if s == "resizable" {
			resizable = true
		} else {
			lua.L_error(L, cstring("window.init: unknown flag"))
		}

		lua.pop(L, 1)
		i += 1
	}

	return
}

// apply_window_flags applies fullscreen/borderless/resizable via SDL setters.
apply_window_flags :: proc "contextless" (fullscreen, borderless, resizable: bool) {
	if Window == nil {
		return
	}

	// Fullscreen on/off.
	sdl.SetWindowFullscreen(Window, fullscreen)

	// Borderless toggle (borderless == true → bordered = false).
	sdl.SetWindowBordered(Window, !borderless)

	// Resizable toggle.
	sdl.SetWindowResizable(Window, resizable)
}

// lua_window_init implements window.init(width, height, title, flags?).
lua_window_init :: proc "c" (L: ^lua.State) -> c.int {
	// Provide a default context for any string helpers used here.
	context = runtime.default_context()

	nargs := lua.gettop(L)
	if nargs < 3 {
		lua.L_error(L, cstring("window.init expects at least 3 arguments: width, height, title[, flags]"))
		return 0
	}

	if Window != nil || Renderer != nil {
		lua.L_error(L, cstring("window.init: window already created"))
		return 0
	}

	w := lua.L_checkinteger(L, 1)
	h := lua.L_checkinteger(L, 2)

	title_c := lua.L_checkstring(L, 3)

	fullscreen, borderless, resizable: bool
	if nargs >= 4 && lua.type(L, 4) == lua.Type.TABLE {
		fullscreen, borderless, resizable = read_window_flags(L, lua.Index(4))
	}

	if !sdl.CreateWindowAndRenderer(
		title_c,
		cast(c.int)(w),
		cast(c.int)(h),
		{}, // initial flags; runtime toggles applied below
		&Window,
		&Renderer,
	) {
		fmt.eprintln("CreateWindowAndRenderer failed:", sdl.GetError())
		lua.L_error(L, cstring("window.init: CreateWindowAndRenderer failed"))
		return 0
	}

	apply_window_flags(fullscreen, borderless, resizable)
	return 0
}

// lua_window_width implements window.width() -> width in pixels.
lua_window_width :: proc "c" (L: ^lua.State) -> c.int {
	if Window == nil {
		lua.L_error(L, cstring("window.width: window not created"))
		return 0
	}

	w, h: c.int
	if !sdl.GetWindowSize(Window, &w, &h) {
		lua.L_error(L, cstring("window.width: GetWindowSize failed"))
		return 0
	}

	lua.pushinteger(L, cast(lua.Integer)(w))
	return 1
}

// lua_window_height implements window.height() -> height in pixels.
lua_window_height :: proc "c" (L: ^lua.State) -> c.int {
	if Window == nil {
		lua.L_error(L, cstring("window.height: window not created"))
		return 0
	}

	w, h: c.int
	if !sdl.GetWindowSize(Window, &w, &h) {
		lua.L_error(L, cstring("window.height: GetWindowSize failed"))
		return 0
	}

	lua.pushinteger(L, cast(lua.Integer)(h))
	return 1
}

// lua_window_columns implements window.columns() -> number of cell columns.
lua_window_columns :: proc "c" (L: ^lua.State) -> c.int {
	if Window == nil {
		lua.L_error(L, cstring("window.columns: window not created"))
		return 0
	}

	if Cell_W <= 0 {
		lua.L_error(L, cstring("window.columns: Cell_W not initialized"))
		return 0
	}

	w, h: c.int
	if !sdl.GetWindowSize(Window, &w, &h) {
		lua.L_error(L, cstring("window.columns: GetWindowSize failed"))
		return 0
	}

	cols := int(f32(w) / Cell_W)
	lua.pushinteger(L, cast(lua.Integer)(cols))
	return 1
}

// lua_window_rows implements window.rows() -> number of cell rows.
lua_window_rows :: proc "c" (L: ^lua.State) -> c.int {
	if Window == nil {
		lua.L_error(L, cstring("window.rows: window not created"))
		return 0
	}

	if Cell_H <= 0 {
		lua.L_error(L, cstring("window.rows: Cell_H not initialized"))
		return 0
	}

	w, h: c.int
	if !sdl.GetWindowSize(Window, &w, &h) {
		lua.L_error(L, cstring("window.rows: GetWindowSize failed"))
		return 0
	}

	rows := int(f32(h) / Cell_H)
	lua.pushinteger(L, cast(lua.Integer)(rows))
	return 1
}

// lua_window_pos_x implements window.pos_x() -> window x in pixels.
lua_window_pos_x :: proc "c" (L: ^lua.State) -> c.int {
	if Window == nil {
		lua.L_error(L, cstring("window.pos_x: window not created"))
		return 0
	}

	x, y: c.int
	if !sdl.GetWindowPosition(Window, &x, &y) {
		lua.L_error(L, cstring("window.pos_x: GetWindowPosition failed"))
		return 0
	}

	lua.pushinteger(L, cast(lua.Integer)(x))
	return 1
}

// lua_window_pos_y implements window.pos_y() -> window y in pixels.
lua_window_pos_y :: proc "c" (L: ^lua.State) -> c.int {
	if Window == nil {
		lua.L_error(L, cstring("window.pos_y: window not created"))
		return 0
	}

	x, y: c.int
	if !sdl.GetWindowPosition(Window, &x, &y) {
		lua.L_error(L, cstring("window.pos_y: GetWindowPosition failed"))
		return 0
	}

	lua.pushinteger(L, cast(lua.Integer)(y))
	return 1
}

// lua_window_set_title implements window.set_title(title).
lua_window_set_title :: proc "c" (L: ^lua.State) -> c.int {
	if Window == nil {
		lua.L_error(L, cstring("window.set_title: window not created"))
		return 0
	}

	title_c := lua.L_checkstring(L, 1)
	sdl.SetWindowTitle(Window, title_c)

	return 0
}

// lua_window_set_size implements window.set_size(width, height) in pixels.
lua_window_set_size :: proc "c" (L: ^lua.State) -> c.int {
	if Window == nil {
		lua.L_error(L, cstring("window.set_size: window not created"))
		return 0
	}

	w := lua.L_checkinteger(L, 1)
	h := lua.L_checkinteger(L, 2)

	if !sdl.SetWindowSize(Window, cast(c.int)(w), cast(c.int)(h)) {
		lua.L_error(L, cstring("window.set_size: SetWindowSize failed"))
		return 0
	}

	return 0
}

// lua_window_set_position implements window.set_position(x, y) in pixels.
lua_window_set_position :: proc "c" (L: ^lua.State) -> c.int {
	if Window == nil {
		lua.L_error(L, cstring("window.set_position: window not created"))
		return 0
	}

	x := lua.L_checkinteger(L, 1)
	y := lua.L_checkinteger(L, 2)

	if !sdl.SetWindowPosition(Window, cast(c.int)(x), cast(c.int)(y)) {
		lua.L_error(L, cstring("window.set_position: SetWindowPosition failed"))
		return 0
	}

	return 0
}

// lua_window_maximize implements window.maximize().
lua_window_maximize :: proc "c" (L: ^lua.State) -> c.int {
	if Window == nil {
		lua.L_error(L, cstring("window.maximize: window not created"))
		return 0
	}

	if !sdl.MaximizeWindow(Window) {
		lua.L_error(L, cstring("window.maximize: MaximizeWindow failed"))
		return 0
	}

	return 0
}

// lua_window_minimize implements window.minimize().
lua_window_minimize :: proc "c" (L: ^lua.State) -> c.int {
	if Window == nil {
		lua.L_error(L, cstring("window.minimize: window not created"))
		return 0
	}

	if !sdl.MinimizeWindow(Window) {
		lua.L_error(L, cstring("window.minimize: MinimizeWindow failed"))
		return 0
	}

	return 0
}

// register_window_api creates the monotome.window table and registers all window procs.
register_window_api :: proc(L: ^lua.State) {
	lua.newtable(L) // [window]

	lua.pushcfunction(L, lua_window_init)
	lua.setfield(L, -2, cstring("init"))

	lua.pushcfunction(L, lua_window_width)
	lua.setfield(L, -2, cstring("width"))

	lua.pushcfunction(L, lua_window_height)
	lua.setfield(L, -2, cstring("height"))

	lua.pushcfunction(L, lua_window_columns)
	lua.setfield(L, -2, cstring("columns"))

	lua.pushcfunction(L, lua_window_rows)
	lua.setfield(L, -2, cstring("rows"))

	lua.pushcfunction(L, lua_window_pos_x)
	lua.setfield(L, -2, cstring("pos_x"))

	lua.pushcfunction(L, lua_window_pos_y)
	lua.setfield(L, -2, cstring("pos_y"))

	lua.pushcfunction(L, lua_window_set_title)
	lua.setfield(L, -2, cstring("set_title"))

	lua.pushcfunction(L, lua_window_set_size)
	lua.setfield(L, -2, cstring("set_size"))

	lua.pushcfunction(L, lua_window_set_position)
	lua.setfield(L, -2, cstring("set_position"))

	lua.pushcfunction(L, lua_window_maximize)
	lua.setfield(L, -2, cstring("maximize"))

	lua.pushcfunction(L, lua_window_minimize)
	lua.setfield(L, -2, cstring("minimize"))
}

