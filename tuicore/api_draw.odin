package main

// api_draw.odin
//
// draw.* Lua API (cell-based terminal primitives), backed by raylib.
//
// Notes:
// - Uses global Cell_W/Cell_H and Active_Font[] owned by the host.
// - draw.glyph renders only the first UTF-8 codepoint from `text`.
// - PERF_TEST_ENABLED/Perf_* counters are optional globals defined elsewhere.

import rl  "vendor:raylib"
import lua "luajit"
import c   "core:c"



// -----------------------------------------------------------------------------
// Registration
// -----------------------------------------------------------------------------


// register_draw_api creates the global Lua table `draw` and installs all functions.

register_draw_api :: proc(L: ^lua.State) {
	lua.newtable(L)
	lua.pushcfunction(L, lua_draw_clear); lua.setfield(L, -2, cstring("clear"))
	lua.pushcfunction(L, lua_draw_cell);  lua.setfield(L, -2, cstring("cell"))
	lua.pushcfunction(L, lua_draw_glyph); lua.setfield(L, -2, cstring("glyph"))
	lua.setglobal(L, cstring("draw"))
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


// -----------------------------------------------------------------------------
// Lua draw API (global table `draw`)
// -----------------------------------------------------------------------------


// draw.clear({r,g,b,a})

lua_draw_clear :: proc "c" (L: ^lua.State) -> c.int {
	when PERF_TEST_ENABLED { Perf_Clear_Calls += 1 }

	col := read_rgba_table(L, 1)
	rl.ClearBackground(col)
	return 0
}


// draw.cell(x, y, {r,g,b,a})
// Fills a cell rectangle (cell coords, not pixels).

lua_draw_cell :: proc "c" (L: ^lua.State) -> c.int {
	when PERF_TEST_ENABLED { Perf_Cell_Calls += 1 }

	x := cast(i32)(lua.L_checkinteger(L, 1))
	y := cast(i32)(lua.L_checkinteger(L, 2))
	col := read_rgba_table(L, 3)

	rl.DrawRectangle(x * Cell_W, y * Cell_H, Cell_W, Cell_H, col)
	return 0
}


// draw.glyph(x, y, {r,g,b,a}, text, face) draws one cell from the first UTF-8 codepoint.
// Special-case: █ is rendered as a filled cell (no font gaps).

lua_draw_glyph :: proc "c" (L: ^lua.State) -> c.int {
	when PERF_TEST_ENABLED { Perf_Glyph_Calls += 1 }

	x := cast(i32)(lua.L_checkinteger(L, 1))
	y := cast(i32)(lua.L_checkinteger(L, 2))
	col := read_rgba_table(L, 3)

	text := lua.L_checkstring(L, 4)
	face := cast(i32)(lua.L_checkinteger(L, 5))

	cp_size: c.int = 0
	cp := rl.GetCodepoint(text, &cp_size)

	// Guard: face must be in [0..3] (error on misuse).
	if face < 0 || face > 3 {
		lua.L_error(L, cstring("draw.glyph: face out of range (expected 0..3, got %d)"), face)
		return 0
	}

	// Policy: only BASE_CODEPOINTS may use non-regular faces (coverage fallback to face 0).
	base_ok := false
	for r in BASE_CODEPOINTS {
		if cp >= r.first && cp <= r.last {
			base_ok = true
			break
		}
	}
	if !base_ok {
		face = 0
	}

	// █ => filled cell (perfect, avoids raster seams).
	if cp == rune(0x2588) {
		rl.DrawRectangle(x * Cell_W, y * Cell_H, Cell_W, Cell_H, col)
		return 0
	}

	font := Active_Font[face]
	gi := rl.GetGlyphInfo(font, cp)
	src := rl.GetGlyphAtlasRec(font, cp)

	// Cell bounds (clip rect).
	cell_x := cast(f32)(x * Cell_W)
	cell_y := cast(f32)(y * Cell_H)
	clip_l := cell_x
	clip_t := cell_y
	clip_r := cell_x + cast(f32)(Cell_W)
	clip_b := cell_y + cast(f32)(Cell_H)

	// Glyph natural destination in this cell.
	dst_l := cell_x + cast(f32)(gi.offsetX)
	dst_t := cell_y + cast(f32)(gi.offsetY)
	dst_r := dst_l + src.width
	dst_b := dst_t + src.height

	// Intersect glyph dst with cell clip.
	ix_l := dst_l
	if clip_l > ix_l { ix_l = clip_l }
	ix_t := dst_t
	if clip_t > ix_t { ix_t = clip_t }
	ix_r := dst_r
	if clip_r < ix_r { ix_r = clip_r }
	ix_b := dst_b
	if clip_b < ix_b { ix_b = clip_b }

	iw := ix_r - ix_l
	ih := ix_b - ix_t
	if iw <= 0.0 || ih <= 0.0 {
		return 0
	}

	// Trim source by the same amount trimmed from destination (1:1 scale).
	src.x += (ix_l - dst_l)
	src.y += (ix_t - dst_t)
	src.width  = iw
	src.height = ih

	dst := rl.Rectangle{ix_l, ix_t, iw, ih}
	rl.DrawTexturePro(font.texture, src, dst, rl.Vector2{0, 0}, 0.0, col)
	return 0
}
