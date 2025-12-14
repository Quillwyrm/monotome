package main

// -----------------------------------------------------------------------------
// Qterm / tuicore prototype
//
// Purpose:
// - Minimal monospace grid renderer driven by Lua callbacks.
// - User font size is UI points (like normal editors), converted to pixel-ish size.
// - Box/line glyph overflow is handled by cropping the glyph quad to the cell.
//
// Lua contract:
// - Must define: init_terminal(), update_terminal(dt), draw_terminal()
// - Exposes: draw.clear(rgba), draw.cell(x,y,rgba), draw.glyph(x,y,rgba,text,face)
// - Exposes globals: TERM_COLS, TERM_ROWS
//
// Notes:
// - draw.glyph draws ONLY the first UTF-8 codepoint from `text` (one cell).
// - Baked codepoint set is prototype-only (ASCII + a few box/block glyphs).
// -----------------------------------------------------------------------------

import rl       "vendor:raylib"
import lua      "luajit"
import os       "core:os"
import strings  "core:strings"
import filepath "core:path/filepath"
import c        "core:c"


// -----------------------------------------------------------------------------
// Global config/state
// -----------------------------------------------------------------------------

// User-facing font size (UI points, typical editor UX).
Font_Pt: c.int = 15

// Internal raster size passed to LoadFontEx (computed at startup).
Font_Px: c.int

// Face order: 0=Regular, 1=Bold, 2=Italic, 3=BoldItalic
Font_Path: [4]cstring = {
	cstring("C:\\dev\\dev_tuicore\\tuicore\\fonts\\JetBrainsMono-Regular.ttf"),
	cstring("C:\\dev\\dev_tuicore\\tuicore\\fonts\\JetBrainsMono-Bold.ttf"),
	cstring("C:\\dev\\dev_tuicore\\tuicore\\fonts\\JetBrainsMono-Italic.ttf"),
	cstring("C:\\dev\\dev_tuicore\\tuicore\\fonts\\JetBrainsMono-BoldItalic.ttf"),
}

Active_Font: [4]rl.Font

// Cell metrics in pixels.
Cell_W: i32
Cell_H: i32


// -----------------------------------------------------------------------------
// Lua data helpers
// -----------------------------------------------------------------------------

// read_rgba_table reads Lua table {r,g,b,a} (1-based) into rl.Color.
// Minimal: no validation, no defaults.
read_rgba_table :: proc "contextless" (L: ^lua.State, idx: lua.Index) -> rl.Color {
	lua.rawgeti(L, idx, cast(lua.Integer)(1))
	r := cast(u8)(lua.tointeger(L, -1))
	lua.pop(L, 1)

	lua.rawgeti(L, idx, cast(lua.Integer)(2))
	g := cast(u8)(lua.tointeger(L, -1))
	lua.pop(L, 1)

	lua.rawgeti(L, idx, cast(lua.Integer)(3))
	b := cast(u8)(lua.tointeger(L, -1))
	lua.pop(L, 1)

	lua.rawgeti(L, idx, cast(lua.Integer)(4))
	a := cast(u8)(lua.tointeger(L, -1))
	lua.pop(L, 1)

	return rl.Color{r, g, b, a}
}


// -----------------------------------------------------------------------------
// Lua globals + API binding
// -----------------------------------------------------------------------------

// update_lua_globals updates Lua globals that depend on window/render size.
// Uses render size (HiDPI aware) and current Cell_W/Cell_H.
update_lua_globals :: proc(L: ^lua.State) {
	w := cast(i32)(rl.GetRenderWidth())
	h := cast(i32)(rl.GetRenderHeight())

	lua.pushinteger(L, cast(lua.Integer)(w / Cell_W))
	lua.setglobal(L, cstring("TERM_COLS"))

	lua.pushinteger(L, cast(lua.Integer)(h / Cell_H))
	lua.setglobal(L, cstring("TERM_ROWS"))
}

// bind_lua_api registers everything this program exposes to Lua.
// Call AFTER Cell_W/Cell_H are computed.
bind_lua_api :: proc(L: ^lua.State) {
	// draw table
	lua.newtable(L)
	lua.pushcfunction(L, lua_draw_clear); lua.setfield(L, -2, cstring("clear"))
	lua.pushcfunction(L, lua_draw_cell);  lua.setfield(L, -2, cstring("cell"))
	lua.pushcfunction(L, lua_draw_glyph); lua.setfield(L, -2, cstring("glyph"))
	lua.setglobal(L, cstring("draw"))

	// globals (TERM_COLS/TERM_ROWS)
	update_lua_globals(L)
}


// -----------------------------------------------------------------------------
// Lua draw API (global table `draw`)
// -----------------------------------------------------------------------------

// draw.clear({r,g,b,a})
lua_draw_clear :: proc "c" (L: ^lua.State) -> c.int {
	col := read_rgba_table(L, 1)
	rl.ClearBackground(col)
	return 0
}

// draw.cell(x, y, {r,g,b,a})
// Fills a cell rectangle (cell coords, not pixels).
lua_draw_cell :: proc "c" (L: ^lua.State) -> c.int {
	x := cast(i32)(lua.tointeger(L, 1))
	y := cast(i32)(lua.tointeger(L, 2))
	col := read_rgba_table(L, 3)

	rl.DrawRectangle(x * Cell_W, y * Cell_H, Cell_W, Cell_H, col)
	return 0
}


// draw.glyph(x, y, {r,g,b,a}, text, face)
// Draws ONE cell: uses first UTF-8 codepoint from `text`.
// Special-case: █ is rendered as a filled cell (no font gaps).
lua_draw_glyph :: proc "c" (L: ^lua.State) -> c.int {
	x := cast(i32)(lua.tointeger(L, 1))
	y := cast(i32)(lua.tointeger(L, 2))
	col := read_rgba_table(L, 3)

	text := lua.L_checkstring(L, 4)
	face := cast(i32)(lua.tointeger(L, 5))

	cp_size: c.int = 0
	cp := rl.GetCodepoint(text, &cp_size)

	cell_px_x := x * Cell_W
	cell_px_y := y * Cell_H

	// █ => filled cell (perfect, avoids raster seams)
	if cp == rune(0x2588) {
		rl.DrawRectangle(cell_px_x, cell_px_y, Cell_W, Cell_H, col)
		return 0
	}

	gi := rl.GetGlyphInfo(Active_Font[face], cp)
	src := rl.GetGlyphAtlasRec(Active_Font[face], cp)

	// Natural glyph destination rect for this cell.
	dst := rl.Rectangle{
		x      = cast(f32)(cell_px_x) + cast(f32)(gi.offsetX),
		y      = cast(f32)(cell_px_y) + cast(f32)(gi.offsetY),
		width  = src.width,
		height = src.height,
	}

	// Cell clip rect.
	clip := rl.Rectangle{
		x      = cast(f32)(cell_px_x),
		y      = cast(f32)(cell_px_y),
		width  = cast(f32)(Cell_W),
		height = cast(f32)(Cell_H),
	}

	// Intersection of glyph dst with cell clip.
	inter := rl.GetCollisionRec(dst, clip)
	if inter.width <= 0.0 || inter.height <= 0.0 {
		return 0
	}

	// Trim source by the same amount trimmed from destination (1:1 scale).
	src.x += (inter.x - dst.x)
	src.y += (inter.y - dst.y)
	src.width  = inter.width
	src.height = inter.height

	dst = inter

	rl.DrawTexturePro(Active_Font[face].texture, src, dst, rl.Vector2{0, 0}, 0.0, col)
	return 0
}


// -----------------------------------------------------------------------------
// Lua call helpers (proc-group)
// -----------------------------------------------------------------------------

// call_lua_noargs calls global Lua function name() -> no returns.
call_lua_noargs :: proc(L: ^lua.State, name: cstring) -> bool {
	lua.getglobal(L, name)
	ok := lua.pcall(L, 0, 0, 0) == lua.Status.OK
	lua.settop(L, 0)
	return ok
}

// call_lua_number calls global Lua function name(x) -> no returns.
call_lua_number :: proc(L: ^lua.State, name: cstring, x: f64) -> bool {
	lua.getglobal(L, name)
	lua.pushnumber(L, cast(lua.Number)(x))
	ok := lua.pcall(L, 1, 0, 0) == lua.Status.OK
	lua.settop(L, 0)
	return ok
}

call_lua :: proc{call_lua_noargs, call_lua_number}


// -----------------------------------------------------------------------------
// main
// -----------------------------------------------------------------------------

main :: proc() {
	// Window
	rl.SetConfigFlags(rl.ConfigFlags{.WINDOW_RESIZABLE})
	rl.InitWindow(800, 450, cstring("Qterm"))
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	// UI points -> pixels (logical DPI model)
	// baseline: 96 dpi, 1pt = 1/72 inch => px = pt * 96/72 = pt * 4/3
	s := rl.GetWindowScaleDPI()
	scale := s[0]
	if scale <= 0.0 { scale = 1.0 }

	px_f := cast(f32)(Font_Pt) * (4.0 / 3.0) * scale
	Font_Px = cast(c.int)(px_f + 0.5)
	if Font_Px < 1 { Font_Px = 1 }

	// Prototype bake set: ASCII + a few box/block glyphs used in demos.
	codepoints: [256]rune
	n: c.int = 0
	for cp := rune(32); cp <= rune(126); cp += 1 {
		codepoints[cast(int)(n)] = cp
		n += 1
	}
	codepoints[cast(int)(n)] = rune(0x2500); n += 1 // ─
	codepoints[cast(int)(n)] = rune(0x2502); n += 1 // │
	codepoints[cast(int)(n)] = rune(0x250C); n += 1 // ┌
	codepoints[cast(int)(n)] = rune(0x2510); n += 1 // ┐
	codepoints[cast(int)(n)] = rune(0x2514); n += 1 // └
	codepoints[cast(int)(n)] = rune(0x2518); n += 1 // ┘
	codepoints[cast(int)(n)] = rune(0x253C); n += 1 // ┼
	codepoints[cast(int)(n)] = rune(0x2588); n += 1 // █

	// Load fonts
	for i in 0..<4 {
		Active_Font[i] = rl.LoadFontEx(Font_Path[i], Font_Px, &codepoints[0], n)
		rl.SetTextureFilter(Active_Font[i].texture, rl.TextureFilter.POINT)
		rl.SetTextureWrap(Active_Font[i].texture, rl.TextureWrap.CLAMP)
	}
	defer {
		for i in 0..<4 {
			rl.UnloadFont(Active_Font[i])
		}
	}

	// Cell metrics: width from monospace advance (so box drawing joins).
	max_adv: c.int = 1
	for i: c.int = 0; i < n; i += 1 {
		cp := codepoints[cast(int)(i)]
		adv := rl.GetGlyphInfo(Active_Font[0], cp).advanceX
		if adv > max_adv { max_adv = adv }
	}
	Cell_W = cast(i32)(max_adv)

	Cell_H = cast(i32)(Active_Font[0].baseSize)
	if Cell_H <= 0 { Cell_H = 1 }

	// Lua state
	L := lua.L_newstate()
	defer lua.close(L)
	lua.L_openlibs(L)

	// Bind Lua surface (tables + globals)
	bind_lua_api(L)

	// Load main.lua next to the executable.
	engine_dir := filepath.dir(os.args[0])
	main_path, jerr := filepath.join([]string{engine_dir, "main.lua"})
	if jerr != .None { return }
	defer delete(main_path)

	main_cstr, cerr := strings.clone_to_cstring(main_path)
	if cerr != .None { return }
	defer delete(main_cstr)

	if lua.L_dofile(L, main_cstr) != lua.Status.OK { return }
	lua.settop(L, 0)

	// Lua init
	if !call_lua(L, cstring("init_terminal")) { return }

	// Main loop
	last_time := rl.GetTime()
	for !rl.WindowShouldClose() {
		if rl.IsWindowResized() {
			update_lua_globals(L)
		}

		now := rl.GetTime()
		dt := now - last_time
		last_time = now

		if !call_lua(L, cstring("update_terminal"), dt) { break }

		rl.BeginDrawing()
		if !call_lua(L, cstring("draw_terminal")) {
			rl.EndDrawing()
			break
		}
		rl.EndDrawing()
	}
}

