package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:c"
import "core:unicode/utf8"
import sdl "vendor:sdl3"
import "vendor:sdl3/ttf"
import lua "luajit"



//========================================================================================================================================
// HOST DRAW HELPERS
// Core rendering helpers
//========================================================================================================================================

// draw_text renders a cached single glyph (rune) in cell space using the active font and Text_Engine.
draw_text :: proc(x, y: int, r: rune, color: sdl.Color, face: int) {
	if Text_Engine == nil {
		panic("draw_text: Text_Engine is nil")
	}
	if face < 0 || face > 3 {
		return
	}
	if Active_Font[face] == nil {
		return
	}

	// Lazily allocate map for this face.
	if Text_Cache[face] == nil {
		Text_Cache[face] = make(map[rune]^ttf.Text)
	}

	// Look up existing cached glyph.
	text_obj, ok := Text_Cache[face][r]

	// Create on first use (no heap alloc: encode rune into a small stack buffer).
	if !ok || text_obj == nil {
		enc, w := utf8.encode_rune(r) // w in 1..4

		buf: [5]u8 // 4 bytes UTF-8 + NUL
		copy(buf[:w], enc[:w])
		buf[w] = 0

		text_cstr := cast(cstring)(&buf[0])

		text_obj = ttf.CreateText(Text_Engine, Active_Font[face], text_cstr, c.size_t(w))
		if text_obj == nil {
			fmt.eprintln("draw_text: CreateText failed for face", face)
			return
		}

		Text_Cache[face][r] = text_obj
	}

	// Apply color.
	ttf.SetTextColor(text_obj, color.r, color.g, color.b, color.a)

	// Cell → pixels.
	x_px := f32(x) * Cell_W
	y_px := f32(y) * Cell_H

	ttf.DrawRendererText(text_obj, x_px, y_px)
}


// read_rgba_table reads Lua table {r,g,b,a} (1-based) into sdl.Color with no clamping.
read_rgba_table :: proc "contextless" (L: ^lua.State, idx: lua.Index) -> sdl.Color {
	lua.L_checktype(L, cast(c.int)(idx), lua.Type.TABLE)

	r: u8
	g: u8
	b: u8
	a: u8

	lua.rawgeti(L, idx, cast(lua.Integer)(1))
	if lua.type(L, -1) != lua.Type.NUMBER {
		lua.L_error(L, cstring("rgba[1] must be a number"))
		return sdl.Color{}
	}
	r = cast(u8)(cast(f64)(lua.tonumber(L, -1)))
	lua.pop(L, 1)

	lua.rawgeti(L, idx, cast(lua.Integer)(2))
	if lua.type(L, -1) != lua.Type.NUMBER {
		lua.L_error(L, cstring("rgba[2] must be a number"))
		return sdl.Color{}
	}
	g = cast(u8)(cast(f64)(lua.tonumber(L, -1)))
	lua.pop(L, 1)

	lua.rawgeti(L, idx, cast(lua.Integer)(3))
	if lua.type(L, -1) != lua.Type.NUMBER {
		lua.L_error(L, cstring("rgba[3] must be a number"))
		return sdl.Color{}
	}
	b = cast(u8)(cast(f64)(lua.tonumber(L, -1)))
	lua.pop(L, 1)

	lua.rawgeti(L, idx, cast(lua.Integer)(4))
	if lua.type(L, -1) != lua.Type.NUMBER {
		lua.L_error(L, cstring("rgba[4] must be a number"))
		return sdl.Color{}
	}
	a = cast(u8)(cast(f64)(lua.tonumber(L, -1)))
	lua.pop(L, 1)

	color: sdl.Color
	color.r = r
	color.g = g
	color.b = b
	color.a = a
	return color
}

// grid_cols_rows returns the current grid size in whole cells.
grid_cols_rows :: proc "contextless" () -> (cols, rows: int) {
	if Window == nil {
		return 0, 0
	}
	if Cell_W <= 0 || Cell_H <= 0 {
		return 0, 0
	}

	w, h: c.int
	if !sdl.GetWindowSize(Window, &w, &h) {
		return 0, 0
	}

	cols = int(f32(w) / Cell_W)
	rows = int(f32(h) / Cell_H)
	return
}


//========================================================================================================================================
// DRAW API 
// Lua exposed API for handling sdl windowing (monotome.draw.*)
//========================================================================================================================================

// lua_draw_clear implements monotome.draw.clear({r,g,b,a}) using SDL clear,
// and also sets a clip rect to the current cell grid for the rest of the frame.
lua_draw_clear :: proc "c" (L: ^lua.State) -> c.int {
	if lua.gettop(L) < 1 {
		lua.L_error(L, cstring("draw.clear expects 1 argument (rgba table)"))
		return 0
	}

	color := read_rgba_table(L, 1)

	// 1) Disable any existing clip so the clear hits the entire window.
	sdl.SetRenderClipRect(Renderer, nil)

	// 2) Clear whole window to the given color.
	sdl.SetRenderDrawColor(Renderer, color.r, color.g, color.b, color.a)
	sdl.RenderClear(Renderer)

	// 3) Compute grid size and set clip rect to the cell grid in pixels.
	cols, rows := grid_cols_rows()
	if cols > 0 && rows > 0 {
		rect: sdl.Rect
		rect.x = 0
		rect.y = 0
		rect.w = c.int(f32(cols) * Cell_W)
		rect.h = c.int(f32(rows) * Cell_H)
		sdl.SetRenderClipRect(Renderer, &rect)
	}

	return 0
}

// lua_draw_text implements monotome.draw.text(x, y, text, color, face?).
lua_draw_text :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	nargs := lua.gettop(L)
	if nargs < 4 {
		lua.L_error(L, cstring("draw.text expects at least 4 arguments: x, y, text, color"))
		return 0
	}

	start_x := int(lua.L_checkinteger(L, 1))
	y       := int(lua.L_checkinteger(L, 2))

	text_len: c.size_t
	text_c  := lua.L_checklstring(L, 3, &text_len)

	color := read_rgba_table(L, 4)

	// Optional face: Lua 1..4 -> host 0..3. Defaults to 0.
	face := 0
	if nargs >= 5 && !lua.isnil(L, 5) {
		lua_face := int(lua.L_checkinteger(L, 5))
		if lua_face >= 1 && lua_face <= 4 {
			face = lua_face - 1
		} else {
			face = 0
		}
	}

	cols, rows := grid_cols_rows()
	if cols <= 0 || rows <= 0 {
		return 0
	}

	// Strict reject: whole call is OOB in Y => draw nothing.
	if y < 0 || y >= rows {
		return 0
	}

	// Iterate Lua string directly (no cloning). One rune = one cell.
	s := strings.string_from_ptr(cast(^u8)(text_c), int(text_len))

	x := start_x
	for r in s {
		// Strict reject per-cell in X: never partially draw into the grid.
		if x < 0 || x >= cols {
			x += 1
			continue
		}

		draw_text(x, y, r, color, face)
		x += 1
	}

	return 0
}


// lua_draw_rect implements monotome.draw.rect(x, y, w, h, color) in cell space.
// It does a cheap whole-rect OOB test in cell space, and relies on the clip
// rect (set in draw.clear) for pixel-perfect clipping at the edges.
lua_draw_rect :: proc "c" (L: ^lua.State) -> c.int {
	nargs := lua.gettop(L)
	if nargs < 5 {
		lua.L_error(L, cstring("draw.rect expects 5 arguments: x, y, w, h, color"))
		return 0
	}

	x := int(lua.L_checkinteger(L, 1))
	y := int(lua.L_checkinteger(L, 2))
	w := int(lua.L_checkinteger(L, 3))
	h := int(lua.L_checkinteger(L, 4))

	if w <= 0 || h <= 0 {
		return 0
	}

	color := read_rgba_table(L, 5)

	cols, rows := grid_cols_rows()
	if cols <= 0 || rows <= 0 {
		lua.L_error(L, cstring("draw.rect: grid not initialized (Cell_W/H or window size invalid)"))
		return 0
	}

	// Cell -> pixels; rely on SDL clip rect to enforce grid bounds.
	rect: sdl.FRect        // or sdl.Rect, whichever you're already using here
	rect.x = f32(x) * Cell_W
	rect.y = f32(y) * Cell_H
	rect.w = f32(w) * Cell_W
	rect.h = f32(h) * Cell_H

	sdl.SetRenderDrawColor(Renderer, color.r, color.g, color.b, color.a)
	sdl.RenderFillRect(Renderer, &rect)

	return 0
}

// register_draw_api creates the monotome.draw table and registers clear/text/rect procs.
register_draw_api :: proc(L: ^lua.State) {
	lua.newtable(L) // [draw]

	lua.pushcfunction(L, lua_draw_clear)
	lua.setfield(L, -2, cstring("clear"))

	lua.pushcfunction(L, lua_draw_text)
	lua.setfield(L, -2, cstring("text"))

	lua.pushcfunction(L, lua_draw_rect)
	lua.setfield(L, -2, cstring("rect"))
}
