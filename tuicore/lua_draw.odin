package main

// api_draw.odin
//
// draw.* Lua API (cell-based terminal primitives), backed by raylib.
//
// Notes:
// - Uses global Cell_W/Cell_H and Active_Font[] owned by the host.
// - draw.glyph renders only the first UTF-8 codepoint from `text`.
// - draw.text renders UTF-8 text, one glyph per cell, face 0 only.

import rl  "vendor:raylib"
import lua "luajit"
import "core:strings"
import "base:runtime"
import    "core:c"


// -----------------------------------------------------------------------------
// Registration
// -----------------------------------------------------------------------------

register_draw_api :: proc(L: ^lua.State) {
	lua.newtable(L)
	lua.pushcfunction(L, lua_draw_clear); lua.setfield(L, -2, cstring("clear"))
	lua.pushcfunction(L, lua_draw_cell);  lua.setfield(L, -2, cstring("cell"))
	lua.pushcfunction(L, lua_draw_rect);  lua.setfield(L, -2, cstring("rect"))
	lua.pushcfunction(L, lua_draw_glyph); lua.setfield(L, -2, cstring("glyph"))
	lua.pushcfunction(L, lua_draw_text);  lua.setfield(L, -2, cstring("text"))
	push_lua_module(L, cstring("tuicore.draw"))
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
// Host draw primitive (shared core)
// -----------------------------------------------------------------------------

// draw_glyph draws exactly one codepoint into a single cell at (x,y) using face.
// Includes █ special-case and cell-clip logic.
draw_glyph :: proc "contextless" (x, y: i32, color: rl.Color, codepoint: rune, face: i32) {
	// █ => filled cell (perfect, avoids raster seams).
	if codepoint == rune(0x2588) {
		rl.DrawRectangle(x * Cell_W, y * Cell_H, Cell_W, Cell_H, color)
		return
	}

	font := Active_Font[face]
	glyph := rl.GetGlyphInfo(font, codepoint)
	src := rl.GetGlyphAtlasRec(font, codepoint)

	// Cell bounds (clip rect).
	cell_x := cast(f32)(x * Cell_W)
	cell_y := cast(f32)(y * Cell_H)
	clip_l := cell_x
	clip_t := cell_y
	clip_r := cell_x + cast(f32)(Cell_W)
	clip_b := cell_y + cast(f32)(Cell_H)

	// Glyph natural destination in this cell.
	dst_l := cell_x + cast(f32)(glyph.offsetX)
	dst_t := cell_y + cast(f32)(glyph.offsetY)
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

	// Fully clipped.
	if ix_l >= ix_r || ix_t >= ix_b {
		return
	}

	iw := ix_r - ix_l
	ih := ix_b - ix_t

	// Trim source by the same amount trimmed from destination (1:1 scale).
	src.x += (ix_l - dst_l)
	src.y += (ix_t - dst_t)
	src.width  = iw
	src.height = ih

	dst := rl.Rectangle{ix_l, ix_t, iw, ih}
	rl.DrawTexturePro(font.texture, src, dst, rl.Vector2{0, 0}, 0.0, color)
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
// Fills a cell rectangle (cell coords, not pixels).
lua_draw_cell :: proc "c" (L: ^lua.State) -> c.int {
	x := cast(i32)(lua.L_checkinteger(L, 1))
	y := cast(i32)(lua.L_checkinteger(L, 2))
	color := read_rgba_table(L, 3)

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

	rl.DrawRectangle(x * Cell_W, y * Cell_H, w * Cell_W, h * Cell_H, color)
	return 0
}


// draw.glyph(x, y, {r,g,b,a}, text, face)
// Renders the first UTF-8 codepoint from `text` into a single cell.
// face is 0..3; non-base codepoints are forced to face 0 (coverage policy).
lua_draw_glyph :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	
	x := cast(i32)(lua.L_checkinteger(L, 1))
	y := cast(i32)(lua.L_checkinteger(L, 2))
	color := read_rgba_table(L, 3)

	text_len: c.size_t
	text_c := lua.L_checklstring(L, 4, &text_len)
	face := cast(i32)(lua.L_checkinteger(L, 5))

	// Guard: face must be in [0..3] (error on misuse).
	if face < 0 || face > 3 {
		return lua.L_error(L, cstring("draw.glyph: face out of range (expected 0..3, got %d)"), face)
	}

	// Decode the first UTF-8 rune from the Lua string (no pointer math).
	s := strings.string_from_ptr(cast(^u8) text_c, int(text_len))
	if len(s) == 0 {
		return 0
	}

	codepoint: rune
	for r in s {
		codepoint = r
		break
	}

	// Policy: only BASE_CODEPOINTS may use non-regular faces (coverage fallback to face 0).
	base_ok := false
	for r in BASE_CODEPOINTS {
		if codepoint >= r.first && codepoint <= r.last {
			base_ok = true
			break
		}
	}
	if !base_ok {
		face = 0
	}

	draw_glyph(x, y, color, codepoint, face)
	return 0
}


// draw.text(x, y, text, {r,g,b,a}, len?)
// UTF-8 text, one glyph per cell, face 0 only.
// `len` is measured in *cells* (1 rune == 1 cell here). If omitted, there is no limit.
// Newline policy: stop drawing at the first '\n' (single-line primitive).
lua_draw_text :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	
	start_x := cast(i32)(lua.L_checkinteger(L, 1))
	y := cast(i32)(lua.L_checkinteger(L, 2))
	text_len: c.size_t
	text_c := lua.L_checklstring(L, 3, &text_len)
	
	color := read_rgba_table(L, 4)

	max_cells := i32(-1)
	if lua.gettop(L) >= 5 {
		max_cells = cast(i32)(lua.L_checkinteger(L, 5))
	}

	x := start_x
	drawn := i32(0)

	s := strings.string_from_ptr(cast(^u8) text_c, int(text_len))
	for codepoint in s {
		if max_cells >= 0 && drawn >= max_cells {
			break
		}
		if codepoint == rune('\n') {
			break
		}

		draw_glyph(x, y, color, codepoint, 0)
		x += 1
		drawn += 1
	}

	return 0
}

