package main

// Phase 3A (clean):
// - SDL_ttf init + load 4 faces (regular/bold/italic/bold-italic)
// - Derive cell metrics from the regular face (no glyph drawing yet)
// - Resize updates TERM_COLS/TERM_ROWS via window events (no per-frame polling)
//
// Lua API remains:
// - draw.clear({r,g,b,a})
// - draw.cell(col,row,{r,g,b,a})
// - globals: TERM_COLS / TERM_ROWS

import lua      "luajit"
import os       "core:os"
import fmt      "core:fmt"
import strings  "core:strings"
import filepath "core:path/filepath"
import c        "core:c"
import sdl      "vendor:sdl2"
import ttf      "vendor:sdl2/ttf"


// Globals (not const; later you can override from Lua before font load)
Font_Paths: [4]string = [4]string{
	"C:\\dev\\dev_tuicore\\tuicore\\fonts\\JetBrainsMono-Regular.ttf",
	"C:\\dev\\dev_tuicore\\tuicore\\fonts\\JetBrainsMono-Bold.ttf",
	"C:\\dev\\dev_tuicore\\tuicore\\fonts\\JetBrainsMono-Italic.ttf",
	"C:\\dev\\dev_tuicore\\tuicore\\fonts\\JetBrainsMono-BoldItalic.ttf",
}

// 0=regular, 1=bold, 2=italic, 3=bold-italic
Active_Font: [4]^ttf.Font = {}

Font_Size: c.int = 8


Cell_Canvas_State: struct {
	cell_w, cell_h: i32,
	win_w, win_h: i32,
	cols, rows: i32,
	canvas_w, canvas_h: i32,
} = {}

// Renderer target for Lua draw calls (single renderer, single window).
G_Renderer: ^sdl.Renderer = nil


recompute_cell_canvas :: proc(win_w, win_h: i32) {
	Cell_Canvas_State.win_w = win_w
	Cell_Canvas_State.win_h = win_h

	Cell_Canvas_State.cols = win_w / Cell_Canvas_State.cell_w
	Cell_Canvas_State.rows = win_h / Cell_Canvas_State.cell_h

	Cell_Canvas_State.canvas_w = Cell_Canvas_State.cols * Cell_Canvas_State.cell_w
	Cell_Canvas_State.canvas_h = Cell_Canvas_State.rows * Cell_Canvas_State.cell_h
}

sync_term_globals :: proc(L: ^lua.State) {
	lua.pushinteger(L, cast(lua.Integer)(Cell_Canvas_State.cols))
	lua.setglobal(L, cstring("TERM_COLS"))

	lua.pushinteger(L, cast(lua.Integer)(Cell_Canvas_State.rows))
	lua.setglobal(L, cstring("TERM_ROWS"))
}

get_time_seconds :: proc() -> f64 {
	return f64(sdl.GetPerformanceCounter()) / f64(sdl.GetPerformanceFrequency())
}


// ─────────────────────────────────────────────────────────────────────────────
// Pure helper (contextless): read {r,g,b,a} as raw bytes
// ─────────────────────────────────────────────────────────────────────────────

read_rgba_table :: proc "contextless" (L: ^lua.State, idx: c.int) -> (u8, u8, u8, u8) {
	r: u8 = 0
	g: u8 = 0
	b: u8 = 0
	a: u8 = 255

	lua.rawgeti(L, cast(lua.Index)(idx), cast(lua.Integer)(1))
	r = cast(u8)(lua.tointeger(L, -1))
	lua.pop(L, 1)

	lua.rawgeti(L, cast(lua.Index)(idx), cast(lua.Integer)(2))
	g = cast(u8)(lua.tointeger(L, -1))
	lua.pop(L, 1)

	lua.rawgeti(L, cast(lua.Index)(idx), cast(lua.Integer)(3))
	b = cast(u8)(lua.tointeger(L, -1))
	lua.pop(L, 1)

	lua.rawgeti(L, cast(lua.Index)(idx), cast(lua.Integer)(4))
	if lua.isnumber(L, -1) {
		a = cast(u8)(lua.tointeger(L, -1))
	}
	lua.pop(L, 1)

	return r, g, b, a
}


// ─────────────────────────────────────────────────────────────────────────────
// Lua-exposed draw API (proc "c")
// ─────────────────────────────────────────────────────────────────────────────

lua_draw_clear :: proc "c" (L: ^lua.State) -> c.int {
	r: u8 = 0
	g: u8 = 0
	b: u8 = 0
	a: u8 = 255

	if cast(c.int)(lua.gettop(L)) >= 1 {
		lua.L_checktype(L, 1, .TABLE)
		r, g, b, a = read_rgba_table(L, 1)
	}

	if G_Renderer != nil {
		sdl.SetRenderDrawColor(G_Renderer, r, g, b, a)
		sdl.RenderClear(G_Renderer)
	}

	return 0
}

lua_draw_cell :: proc "c" (L: ^lua.State) -> c.int {
	col := cast(i32)(lua.L_checkinteger(L, 1))
	row := cast(i32)(lua.L_checkinteger(L, 2))
	lua.L_checktype(L, 3, .TABLE)

	r, g, b, a := read_rgba_table(L, 3)

	if G_Renderer == nil {
		return 0
	}

	px := col * Cell_Canvas_State.cell_w
	py := row * Cell_Canvas_State.cell_h

	rect := sdl.Rect{
		x = cast(c.int)(px),
		y = cast(c.int)(py),
		w = cast(c.int)(Cell_Canvas_State.cell_w),
		h = cast(c.int)(Cell_Canvas_State.cell_h),
	}

	sdl.SetRenderDrawColor(G_Renderer, r, g, b, a)
	sdl.RenderFillRect(G_Renderer, &rect)

	return 0
}

bind_draw_api :: proc(L: ^lua.State) {
	lua.newtable(L)

	lua.pushcfunction(L, lua_draw_clear)
	lua.setfield(L, -2, cstring("clear"))

	lua.pushcfunction(L, lua_draw_cell)
	lua.setfield(L, -2, cstring("cell"))

	lua.setglobal(L, cstring("draw"))
}


// ─────────────────────────────────────────────────────────────────────────────
// Existing Lua callback helpers (keep minimal)
// ─────────────────────────────────────────────────────────────────────────────

call_lua_noargs :: proc(L: ^lua.State, name: cstring) -> bool {
	lua.getglobal(L, name)
	if !lua.isfunction(L, -1) {
		fmt.printf("Qterm: missing global function %s\n", string(name))
		lua.settop(L, 0)
		return false
	}

	if lua.pcall(L, 0, 0, 0) != lua.Status.OK {
		fmt.printf("Qterm: error in %s: %s\n", string(name), string(lua.tostring(L, -1)))
		lua.settop(L, 0)
		return false
	}

	lua.settop(L, 0)
	return true
}

call_lua_number :: proc(L: ^lua.State, name: cstring, arg: lua.Number) -> bool {
	lua.getglobal(L, name)
	if !lua.isfunction(L, -1) {
		fmt.printf("Qterm: missing global function %s\n", string(name))
		lua.settop(L, 0)
		return false
	}

	lua.pushnumber(L, arg)

	if lua.pcall(L, 1, 0, 0) != lua.Status.OK {
		fmt.printf("Qterm: error in %s: %s\n", string(name), string(lua.tostring(L, -1)))
		lua.settop(L, 0)
		return false
	}

	lua.settop(L, 0)
	return true
}

call_lua :: proc{call_lua_noargs, call_lua_number}


// ─────────────────────────────────────────────────────────────────────────────
// main
// ─────────────────────────────────────────────────────────────────────────────

main :: proc() {
	engine_dir := filepath.dir(os.args[0])

	main_path, jerr := filepath.join([]string{engine_dir, "main.lua"})
	if jerr != .None {
		fmt.printf("Qterm: filepath.join failed: %v\n", jerr)
		return
	}
	defer delete(main_path)

	main_cstr, cerr := strings.clone_to_cstring(main_path)
	if cerr != .None {
		fmt.printf("Qterm: clone_to_cstring failed: %v\n", cerr)
		return
	}
	defer delete(main_cstr)

	assert(sdl.Init(sdl.INIT_VIDEO) == 0, sdl.GetErrorString())
	defer sdl.Quit()

	// Phase 3A: SDL_ttf + 4 faces + real cell metrics.
	assert(ttf.Init() == 0, string(ttf.GetError()))
	defer ttf.Quit()

	defer {
		for i in 0..<4 {
			if Active_Font[i] != nil {
				ttf.CloseFont(Active_Font[i])
				Active_Font[i] = nil
			}
		}
	}

	for i in 0..<4 {
		p, perr := strings.clone_to_cstring(Font_Paths[i])
		if perr != .None {
			fmt.printf("Qterm: clone_to_cstring font path failed: %v\n", perr)
			return
		}
		Active_Font[i] = ttf.OpenFont(p, Font_Size)
		delete(p)
		assert(Active_Font[i] != nil, string(ttf.GetError()))
	}

	// Derive cell metrics from regular face (index 0).
	{
		Cell_Canvas_State.cell_h = cast(i32)(ttf.FontLineSkip(Active_Font[0]))
		assert(Cell_Canvas_State.cell_h > 0, "TTF FontLineSkip <= 0")

		minx, maxx, miny, maxy, advance: c.int
		assert(ttf.GlyphMetrics32(Active_Font[0], 'M', &minx, &maxx, &miny, &maxy, &advance) == 0, string(ttf.GetError()))
		Cell_Canvas_State.cell_w = cast(i32)(advance)
		assert(Cell_Canvas_State.cell_w > 0, "TTF GlyphMetrics advance <= 0")
	}

	window := sdl.CreateWindow(
		"Qterm",
		sdl.WINDOWPOS_CENTERED, sdl.WINDOWPOS_CENTERED,
		800, 450,
		sdl.WindowFlags{.SHOWN, .RESIZABLE},
	)
	assert(window != nil, sdl.GetErrorString())
	defer sdl.DestroyWindow(window)

	renderer := sdl.CreateRenderer(window, -1, sdl.RENDERER_ACCELERATED)
	assert(renderer != nil, sdl.GetErrorString())
	defer sdl.DestroyRenderer(renderer)

	G_Renderer = renderer

	L := (^lua.State)(lua.L_newstate())
	if L == nil {
		fmt.println("Qterm: failed to create Lua state")
		return
	}
	defer lua.close(L)

	lua.L_openlibs(L)

	// Bind draw API before loading script.
	bind_draw_api(L)

	if lua.L_dofile(L, main_cstr) != lua.Status.OK {
		fmt.printf("Qterm: error loading main.lua: %s\n", string(lua.tostring(L, -1)))
		lua.settop(L, 0)
		return
	}

	// Prime canvas + TERM_COLS/ROWS once.
	{
		w, h: i32
		sdl.GetWindowSize(window, &w, &h)
		recompute_cell_canvas(w, h)
		sync_term_globals(L)
	}

	if !call_lua(L, cstring("init_terminal")) {
		return
	}

	running   := true
	last_time := get_time_seconds()

	for running {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			if event.type == .QUIT {
				running = false
			} else if event.type == .WINDOWEVENT {
				// No per-frame polling: recompute on any window event (cheap + correct).
				w, h: i32
				sdl.GetWindowSize(window, &w, &h)
				recompute_cell_canvas(w, h)
				sync_term_globals(L)
			}
		}

		now := get_time_seconds()
		dt  := now - last_time
		last_time = now

		if !call_lua(L, cstring("update_terminal"), cast(lua.Number)(dt)) {
			break
		}

		// Lua is responsible for clearing + drawing (IMGUI style).
		if !call_lua(L, cstring("draw_terminal")) {
			break
		}

		// Optional: keep the Phase 1 canvas outline (helps sanity while resizing).
		{
			r := sdl.Rect{
				x = 0,
				y = 0,
				w = cast(c.int)(Cell_Canvas_State.canvas_w),
				h = cast(c.int)(Cell_Canvas_State.canvas_h),
			}
			sdl.SetRenderDrawColor(renderer, u8(0), u8(255), u8(0), u8(255))
			sdl.RenderDrawRect(renderer, &r)
		}

		sdl.RenderPresent(renderer)
	}
}

