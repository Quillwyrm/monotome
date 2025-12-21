package main

// api_draw.odin
//
// draw.* Lua API (cell-space primitives), backed by raylib.
//
// Contract (current state):
// - Coordinates are in CELL space (pixels never exposed to Lua).
// - Engine does no layout: no wrapping, no alignment, no clipping beyond grid bounds.
// - draw.text is a single-line primitive: it stops at '\n'.
// - face is a direct choice (Lua 1..4 -> host 0..3). No gating, no fallback magic.
//
// Notes:
// - Uses global Cell_W/Cell_H, Font_Size, and Active_Font[] owned by the host.
// - draw.glyph draws only the first UTF-8 codepoint from `text`.
// - draw.cell fills a single cell rectangle (background fill).

import rl  "vendor:raylib"
import lua "luajit"

import "base:runtime"
import "core:c"
import "core:strings"

// -----------------------------------------------------------------------------
// Registration
// -----------------------------------------------------------------------------

register_draw_api :: proc(L: ^lua.State) {
	lua.newtable(L)

	lua.pushcfunction(L, lua_draw_clear) ; lua.setfield(L, -2, cstring("clear"))
	lua.pushcfunction(L, lua_draw_cell)  ; lua.setfield(L, -2, cstring("cell"))
	lua.pushcfunction(L, lua_draw_rect)  ; lua.setfield(L, -2, cstring("rect"))
	lua.pushcfunction(L, lua_draw_text)  ; lua.setfield(L, -2, cstring("text"))

	// draw.set_box_draw_mode("native"|"font")
	lua.pushcfunction(L, lua_draw_set_box_draw_mode) ; lua.setfield(L, -2, cstring("set_box_draw_mode"))
}

// -----------------------------------------------------------------------------
// Lua data helpers
// -----------------------------------------------------------------------------

// read_rgba_table reads Lua table {r,g,b,a} (1-based) into rl.Color.
// Requires a table with 4 numeric entries; no clamping.
read_rgba_table :: proc "contextless" (L: ^lua.State, idx: lua.Index) -> rl.Color {
	lua.L_checktype(L, cast(c.int)(idx), lua.Type.TABLE)

	lua.rawgeti(L, idx, cast(lua.Integer)(1))
	if lua.type(L, -1) != lua.Type.NUMBER {
		lua.L_error(L, cstring("rgba[1] must be a number"))
		return rl.Color{}
	}
	r := cast(u8)(cast(f64)(lua.tonumber(L, -1)))
	lua.pop(L, 1)

	lua.rawgeti(L, idx, cast(lua.Integer)(2))
	if lua.type(L, -1) != lua.Type.NUMBER {
		lua.L_error(L, cstring("rgba[2] must be a number"))
		return rl.Color{}
	}
	g := cast(u8)(cast(f64)(lua.tonumber(L, -1)))
	lua.pop(L, 1)

	lua.rawgeti(L, idx, cast(lua.Integer)(3))
	if lua.type(L, -1) != lua.Type.NUMBER {
		lua.L_error(L, cstring("rgba[3] must be a number"))
		return rl.Color{}
	}
	b := cast(u8)(cast(f64)(lua.tonumber(L, -1)))
	lua.pop(L, 1)

	lua.rawgeti(L, idx, cast(lua.Integer)(4))
	if lua.type(L, -1) != lua.Type.NUMBER {
		lua.L_error(L, cstring("rgba[4] must be a number"))
		return rl.Color{}
	}
	a := cast(u8)(cast(f64)(lua.tonumber(L, -1)))
	lua.pop(L, 1)

	return rl.Color{r, g, b, a}
}

// Returns the drawable grid size (in CELLS), derived from render size.
grid_cols_rows :: proc "contextless" () -> (cols, rows: i32) {
	return cast(i32)(rl.GetRenderWidth()) / Cell_W,
	       cast(i32)(rl.GetRenderHeight()) / Cell_H
}

// -----------------------------------------------------------------------------
// Host draw primitive (shared core)
// -----------------------------------------------------------------------------

// Thickness:
// t = clamp(1, min(Cell_W, Cell_H)/8, 4)
// NOTE: higher divisor => thinner lines.
BOX_STROKE_DIV: i32 = 6
BOX_STROKE_MAX: i32 = 3

// When centering isn't representable (odd/even mismatch), snap by 1px.
// 0 = bias left/up, 1 = bias right/down.
BOX_CENTER_BIAS_X: i32 = 0
BOX_CENTER_BIAS_Y: i32 = 0

// Box drawing render policy for the 11 UI glyphs (─│┌┐└┘├┤┬┴┼):
// 0 = "native" (rect geometry via draw_line_cell)
// 1 = "font"   (render the glyph from the current font)
Box_Draw_Mode: i32 = 0
// draw_line_cell draws the single-line box drawing UI glyphs using rect geometry.
// Returns true if it handled `codepoint`, else false.
//
// Glyphs handled (11):
// ─│┌┐└┘├┤┬┴┼
draw_line_cell :: proc "contextless" (x, y: i32, codepoint: rune, color: rl.Color) -> bool {
	// Direction bits: N=1, E=2, S=4, W=8
	N: u8 = 1
	E: u8 = 2
	S: u8 = 4
	W: u8 = 8

	mask: u8 = 0

	switch codepoint {
	case rune(0x2500): mask = W | E               // ─
	case rune(0x2502): mask = N | S               // │
	case rune(0x250C): mask = E | S               // ┌
	case rune(0x2510): mask = W | S               // ┐
	case rune(0x2514): mask = E | N               // └
	case rune(0x2518): mask = W | N               // ┘
	case rune(0x251C): mask = N | S | E           // ├
	case rune(0x2524): mask = N | S | W           // ┤
	case rune(0x252C): mask = W | E | S           // ┬
	case rune(0x2534): mask = W | E | N           // ┴
	case rune(0x253C): mask = N | S | W | E       // ┼
	case:
		return false
	}

	// Cell pixel bounds.
	x0 := x * Cell_W
	y0 := y * Cell_H
	x1 := x0 + Cell_W
	y1 := y0 + Cell_H

	// Thickness from the smaller cell dimension (uniform stroke weight).
	m := Cell_W
	if Cell_H < m { m = Cell_H }

	t := m / BOX_STROKE_DIV
	if t < 1 { t = 1 }
	if t > BOX_STROKE_MAX { t = BOX_STROKE_MAX }

	// Center junction (t x t). If exact centering isn't possible, apply a stable 1px snap.
	jx0 := x0 + (Cell_W - t) / 2
	jy0 := y0 + (Cell_H - t) / 2

	// If (Cell_W - t) is odd, true center is half-pixel; choose a consistent snap.
	if ((Cell_W - t) & 1) != 0 {
		jx0 += BOX_CENTER_BIAS_X
	}
	if ((Cell_H - t) & 1) != 0 {
		jy0 += BOX_CENTER_BIAS_Y
	}

	// Always draw the junction to avoid pinholes.
	rl.DrawRectangle(jx0, jy0, t, t, color)

	// North segment.
	if (mask & N) != 0 {
		h := jy0 - y0
		if h > 0 {
			rl.DrawRectangle(jx0, y0, t, h, color)
		}
	}

	// South segment.
	if (mask & S) != 0 {
		sy := jy0 + t
		h := y1 - sy
		if h > 0 {
			rl.DrawRectangle(jx0, sy, t, h, color)
		}
	}

	// West segment.
	if (mask & W) != 0 {
		w := jx0 - x0
		if w > 0 {
			rl.DrawRectangle(x0, jy0, w, t, color)
		}
	}

	// East segment.
	if (mask & E) != 0 {
		ex := jx0 + t
		w := x1 - ex
		if w > 0 {
			rl.DrawRectangle(ex, jy0, w, t, color)
		}
	}

	return true
}

// draw_glyph draws exactly one codepoint into a single cell at (x,y).
// Policy:
// - fixed grid (Cell_W/Cell_H)
// - grid bounds check only
// - box drawing UI glyphs are engine-drawn geometry when Box_Draw_Mode=="native"
// - face is a direct choice (0..3); no gating, no fallback
draw_glyph :: proc "contextless" (x, y: i32, codepoint: rune, color: rl.Color, requested_face: i32) {
	cols, rows := grid_cols_rows()

	// Grid clipping: do not draw outside bounds.
	if x < 0 || y < 0 || x >= cols || y >= rows {
		return
	}

	// Full-block special case.
	if codepoint == rune(0x2588) {
		rl.DrawRectangle(x * Cell_W, y * Cell_H, Cell_W, Cell_H, color)
		return
	}

	// Engine-drawn box drawing (deterministic, font-independent).
	// If mode is "font", skip this and let the font render the glyph.
	if Box_Draw_Mode == 0 {
		if draw_line_cell(x, y, codepoint, color) {
			return
		}
	}

	// Clamp face to 0..3.
	face := requested_face
	if face < 0 { face = 0 }
	if face > 3 { face = 3 }

	pos := rl.Vector2{
		cast(f32)(x * Cell_W),
		cast(f32)(y * Cell_H),
	}

	rl.DrawTextCodepoint(Active_Font[face], codepoint, pos, cast(f32)(Font_Size), color)
}

// -----------------------------------------------------------------------------
// Lua API
// -----------------------------------------------------------------------------

// draw.clear({r,g,b,a})
lua_draw_clear :: proc "c" (L: ^lua.State) -> c.int {
	color := read_rgba_table(L, 1)
	rl.ClearBackground(color)
	return 0
}

// draw.cell(x, y, {r,g,b,a})
// Fills a single cell rectangle (cell coords, not pixels).
lua_draw_cell :: proc "c" (L: ^lua.State) -> c.int {
	x := cast(i32)(lua.L_checkinteger(L, 1))
	y := cast(i32)(lua.L_checkinteger(L, 2))
	color := read_rgba_table(L, 3)

	cols, rows := grid_cols_rows()
	if x < 0 || y < 0 || x >= cols || y >= rows {
		return 0
	}

	rl.DrawRectangle(x * Cell_W, y * Cell_H, Cell_W, Cell_H, color)
	return 0
}

// draw.rect(x, y, w, h, {r,g,b,a})
// Draws a filled rectangle in *cell space* (converted to pixels internally).
lua_draw_rect :: proc "c" (L: ^lua.State) -> c.int {
	x := cast(i32)(lua.L_checkinteger(L, 1))
	y := cast(i32)(lua.L_checkinteger(L, 2))
	w := cast(i32)(lua.L_checkinteger(L, 3))
	h := cast(i32)(lua.L_checkinteger(L, 4))
	color := read_rgba_table(L, 5)

	if w <= 0 || h <= 0 {
		return 0
	}

	cols, rows := grid_cols_rows()

	// Reject fully out-of-bounds.
	if x >= cols || y >= rows || (x + w) <= 0 || (y + h) <= 0 {
		return 0
	}

	// Clamp in cell space.
	if x < 0 { w += x ; x = 0 }
	if y < 0 { h += y ; y = 0 }
	if x + w > cols { w = cols - x }
	if y + h > rows { h = rows - y }

	if w <= 0 || h <= 0 {
		return 0
	}

	rl.DrawRectangle(x * Cell_W, y * Cell_H, w * Cell_W, h * Cell_H, color)
	return 0
}

// draw.set_box_draw_mode(mode)
//
// mode:
// - "native": draw the 11 UI box glyphs using rect geometry
// - "font":   draw those glyphs using the current font face
lua_draw_set_box_draw_mode :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	mode_len: c.size_t
	mode_c := lua.L_checklstring(L, 1, &mode_len)
	mode := strings.string_from_ptr(cast(^u8)mode_c, int(mode_len))

	if mode == "native" {
		Box_Draw_Mode = 0
		return 0
	}
	if mode == "font" {
		Box_Draw_Mode = 1
		return 0
	}

	return lua.L_error(L, cstring("draw.set_box_draw_mode: expected \"native\" or \"font\" (got \"%s\")"), mode_c)
}

// draw.text(x, y, text, {r,g,b,a}, face?)
// Renders UTF-8 text horizontally, one codepoint per grid cell.
// Stops at newline.
lua_draw_text :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	start_x := cast(i32)(lua.L_checkinteger(L, 1))
	y := cast(i32)(lua.L_checkinteger(L, 2))

	text_len: c.size_t
	text_c := lua.L_checklstring(L, 3, &text_len)

	color := read_rgba_table(L, 4)

	// Optional: face (Lua 1..4 -> host 0..3)
	face := i32(0)
	if lua.gettop(L) >= 5 && !lua.isnil(L, 5) {
		lua_face := cast(i32)(lua.L_checkinteger(L, 5))
		if lua_face >= 1 && lua_face <= 4 {
			face = lua_face - 1
		} else {
			face = 0
		}
	}

	x := start_x

	s := strings.string_from_ptr(cast(^u8)text_c, int(text_len))
	for cp in s {
		// Single-line primitive: stop at newline.
		if cp == '\n' {
			break
		}

		draw_glyph(x, y, cp, color, face)

		x += 1
	}

	return 0
}


//
// Span renderer: one raylib DrawTextEx call.
// - cell-space origin (x,y) -> pixel-space via (Cell_W/Cell_H)
// - single-line: stops at first '\n'
// - face: Lua 1..4 (defaults to 1 -> host face 0)
// - NO per-glyph fallback; the face applies to the whole span
lua_draw_text_span :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	x_cell := cast(i32)(lua.L_checkinteger(L, 1))
	y_cell := cast(i32)(lua.L_checkinteger(L, 2))

	text_len: c.size_t
	text_ptr := lua.L_checklstring(L, 3, &text_len)

	color := read_rgba_table(L, 4)

	// Optional face: Lua 1..4 -> host 0..3. Defaults to regular (0).
	face := i32(0)
	if lua.gettop(L) >= 5 && !lua.isnil(L, 5) {
		lua_face := cast(i32)(lua.L_checkinteger(L, 5))
		if lua_face >= 1 && lua_face <= 4 {
			face = lua_face - 1
		} else {
			// Face fallback only: invalid face => regular.
			face = 0
		}
	}

	// Lua string -> Odin string (bounded by text_len).
	s := strings.string_from_ptr(cast(^u8)text_ptr, int(text_len))
	if len(s) == 0 {
		return 0
	}

	// Single-line: cut at first '\n' (byte scan; '\n' is ASCII).
	cut := len(s)
	for i in 0..<len(s) {
		if s[i] == '\n' {
			cut = i
			break
		}
	}
	if cut == 0 {
		return 0
	}
	if cut != len(s) {
		s = s[:cut]
	}

	pos := rl.Vector2{
		cast(f32)(x_cell * Cell_W),
		cast(f32)(y_cell * Cell_H),
	}

	// DrawTextEx expects NUL-terminated C string.
	s_c := strings.clone_to_cstring(s, context.temp_allocator)

	rl.DrawTextEx(
		Active_Font[face],
		s_c,
		pos,
		cast(f32)(Font_Size_Active),
		0.0,  // spacing (0 keeps mono feel)
		color,
	)

	return 0
}

