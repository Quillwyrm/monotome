package main

// -----------------------------------------------------------------------------
// tuicore prototype
//
// Purpose:
// - Minimal monospace grid renderer driven by Lua callbacks.
// - Font size is UI points (like normal editors), converted to pixel-ish size.
// - Glyph ink overflow is handled by cropping the glyph quad to the cell.
//
// Lua contract:
// - Must define: init_terminal(), update_terminal(dt), draw_terminal()
// - Exposes: draw.clear(rgba), draw.cell(x,y,rgba), draw.glyph(x,y,rgba,text,face)
// - Exposes globals: TERM_COLS, TERM_ROWS
//
// Notes:
// - draw.glyph draws ONLY the first UTF-8 codepoint from `text` (one cell).
// - Bake policy:
//     - Faces 1..3 bake BASE_CODEPOINTS.
//     - Face 0 bakes BASE_CODEPOINTS + REGULAR_CODEPOINTS.
// - Render policy:
//     - If codepoint is NOT in BASE_CODEPOINTS, requested face is forced to 0.
// - Lua errors: load/init/update/draw failures print a traceback and stop.
// - Perf: handled in perftest.odin (optional).
// -----------------------------------------------------------------------------

import rl       "vendor:raylib"
import lua      "luajit"
import os       "core:os"
import fmt      "core:fmt"
import strings  "core:strings"
import filepath "core:path/filepath"
import c        "core:c"


// -----------------------------------------------------------------------------
// Global config/state
// -----------------------------------------------------------------------------

// User-facing font size (UI points, typical editor UX).
Font_Pt: c.int = 18

// Internal raster size passed to LoadFontEx (computed at startup).
Font_Px: c.int

// Face order: 0=Regular, 1=Bold, 2=Italic, 3=BoldItalic.
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
// Codepoint baselines (split: all-faces vs regular-only)
// -----------------------------------------------------------------------------

Codepoint_Range :: struct {
	first, last: rune, // inclusive
}

// Baked into faces 0..3.
// Only these codepoints may use face 1..3 (bold/italic).
BASE_CODEPOINTS: [4]Codepoint_Range = {
	{rune(0x0020), rune(0x007E)}, // Basic Latin (printable ASCII)
	{rune(0x00A0), rune(0x00FF)}, // Latin-1 Supplement
	{rune(0x0100), rune(0x017F)}, // Latin Extended-A
	{rune(0x2000), rune(0x206F)}, // General Punctuation
}

// Baked into face 0 only.
REGULAR_CODEPOINTS: [9]Codepoint_Range = {
	{rune(0x0370), rune(0x03FF)}, // Greek and Coptic
	{rune(0x2100), rune(0x214F)}, // Letterlike Symbols
	{rune(0x2190), rune(0x21FF)}, // Arrows
	{rune(0x2200), rune(0x22FF)}, // Mathematical Operators
	{rune(0x2500), rune(0x259F)}, // Box Drawing + Block Elements
	{rune(0x25A0), rune(0x25FF)}, // Geometric Shapes
	{rune(0x2700), rune(0x27BF)}, // Dingbats

	// Powerline separators (common).
	{rune(0xE0A0), rune(0xE0A2)},
	{rune(0xE0B0), rune(0xE0B3)},
}



// count_ranges counts total codepoints across inclusive ranges.
count_ranges :: proc "contextless" (ranges: []Codepoint_Range) -> int {
	total := 0
	for r in ranges {
		total += cast(int)(r.last - r.first) + 1
	}
	return total
}

// write_ranges expands inclusive ranges into out[] and returns count written.
write_ranges :: proc "contextless" (out: []rune, ranges: []Codepoint_Range) -> int {
	written := 0
	for r in ranges {
		for cp := r.first; cp <= r.last; cp += 1 {
			out[written] = cp
			written += 1
		}
	}
	return written
}


// -----------------------------------------------------------------------------
// Lua data helpers
// -----------------------------------------------------------------------------

// read_rgba_table reads Lua table {r,g,b,a} (1-based) into rl.Color.
// Contract: requires a table with 4 numeric entries; no clamping.
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
// Lua globals + API binding
// -----------------------------------------------------------------------------

// update_lua_globals updates Lua globals that depend on render size.
update_lua_globals :: proc(L: ^lua.State) {
	render_w := cast(i32)(rl.GetRenderWidth())
	render_h := cast(i32)(rl.GetRenderHeight())

	// Invariant: Cell_W/Cell_H are > 0 by construction (set during init).
	lua.pushinteger(L, cast(lua.Integer)(render_w / Cell_W))
	lua.setglobal(L, cstring("TERM_COLS"))

	lua.pushinteger(L, cast(lua.Integer)(render_h / Cell_H))
	lua.setglobal(L, cstring("TERM_ROWS"))
}

// bind_lua_api registers everything this program exposes to Lua.
// Call AFTER Cell_W/Cell_H are computed.
bind_lua_api :: proc(L: ^lua.State) {
	lua.newtable(L)
	lua.pushcfunction(L, lua_draw_clear); lua.setfield(L, -2, cstring("clear"))
	lua.pushcfunction(L, lua_draw_cell);  lua.setfield(L, -2, cstring("cell"))
	lua.pushcfunction(L, lua_draw_glyph); lua.setfield(L, -2, cstring("glyph"))
	lua.setglobal(L, cstring("draw"))

	update_lua_globals(L)
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

// draw.glyph(x, y, {r,g,b,a}, text, face)
// Draws ONE cell: uses first UTF-8 codepoint from `text`.
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


// -----------------------------------------------------------------------------
// Lua errors + call helpers (proc-group)
// -----------------------------------------------------------------------------

// lua_traceback is used as the error handler for lua.pcall.
// It converts an error into a traceback string.
lua_traceback :: proc "c" (L: ^lua.State) -> c.int {
	msg := lua.tostring(L, 1)
	if msg == nil { msg = cstring("Lua error") }
	lua.L_traceback(L, L, msg, 1)
	return 1
}

// call_lua_noargs calls global Lua function name() -> no returns.
// On failure, prints a traceback and returns false.
call_lua_noargs :: proc(L: ^lua.State, name: cstring) -> bool {
	lua.pushcfunction(L, lua_traceback)
	errfunc := lua.gettop(L) // lua.Index (stack slot)

	lua.getglobal(L, name)

	ok := lua.pcall(L, 0, 0, cast(c.int)(errfunc)) == lua.Status.OK
	if !ok {
		err := lua.tostring(L, -1)
		fmt.printf("Lua error in %s:\n%s\n", name, err)
	}

	lua.settop(L, 0)
	return ok
}

// call_lua_number calls global Lua function name(x) -> no returns.
// On failure, prints a traceback and returns false.
call_lua_number :: proc(L: ^lua.State, name: cstring, x: f64) -> bool {
	lua.pushcfunction(L, lua_traceback)
	errfunc := lua.gettop(L)

	lua.getglobal(L, name)
	lua.pushnumber(L, cast(lua.Number)(x))

	ok := lua.pcall(L, 1, 0, cast(c.int)(errfunc)) == lua.Status.OK
	if !ok {
		err := lua.tostring(L, -1)
		fmt.printf("Lua error in %s:\n%s\n", name, err)
	}

	lua.settop(L, 0)
	return ok
}



// -----------------------------------------------------------------------------
// main
// -----------------------------------------------------------------------------

main :: proc() {
	// Window.
	rl.SetConfigFlags(rl.ConfigFlags{.WINDOW_RESIZABLE})
	rl.InitWindow(800, 450, cstring("tuicore"))
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	// UI points -> pixels (logical DPI model).
	// baseline: 96 dpi, 1pt = 1/72 inch => px = pt * 96/72 = pt * 4/3
	s := rl.GetWindowScaleDPI()
	scale := s[0]

	px_f := cast(f32)(Font_Pt) * (4.0 / 3.0) * scale
	Font_Px = cast(c.int)(px_f + 0.5)

	// Build baked codepoint lists from baselines:
	// - Face 0: BASE_CODEPOINTS + REGULAR_CODEPOINTS
	// - Faces 1..3: BASE_CODEPOINTS only
	base_count := count_ranges(BASE_CODEPOINTS[:])
	reg_count  := count_ranges(REGULAR_CODEPOINTS[:])

	base_codepoints := make([]rune, base_count)
	_ = write_ranges(base_codepoints, BASE_CODEPOINTS[:])

	regular_codepoints := make([]rune, base_count + reg_count)
	regular_written := 0
	regular_written += write_ranges(regular_codepoints[regular_written:], BASE_CODEPOINTS[:])
	regular_written += write_ranges(regular_codepoints[regular_written:], REGULAR_CODEPOINTS[:])

	// Load fonts
	Active_Font[0] = rl.LoadFontEx(Font_Path[0], Font_Px, &regular_codepoints[0], cast(c.int)(regular_written))
	rl.SetTextureFilter(Active_Font[0].texture, rl.TextureFilter.POINT)
	rl.SetTextureWrap(Active_Font[0].texture, rl.TextureWrap.CLAMP)

	for i in 1..<4 {
		Active_Font[i] = rl.LoadFontEx(Font_Path[i], Font_Px, &base_codepoints[0], cast(c.int)(base_count))
		rl.SetTextureFilter(Active_Font[i].texture, rl.TextureFilter.POINT)
		rl.SetTextureWrap(Active_Font[i].texture, rl.TextureWrap.CLAMP)
	}

	defer {
		for i in 0..<4 {
			rl.UnloadFont(Active_Font[i])
		}
	}

	// Cell metrics: width from max ASCII advance (stable for monospace).
	max_adv: c.int = 1
	for cp := rune(32); cp <= rune(126); cp += 1 {
		adv := rl.GetGlyphInfo(Active_Font[0], cp).advanceX
		if adv > max_adv { max_adv = adv }
	}
	Cell_W = cast(i32)(max_adv)

	Cell_H = cast(i32)(Active_Font[0].baseSize)
	// Invariant: Cell_H > 0 by construction (font baseSize is expected > 0).

	// Lua state.
	L := lua.L_newstate()
	defer lua.close(L)
	lua.L_openlibs(L)

	// Bind Lua surface (tables + globals).
	bind_lua_api(L)

	// Load main.lua next to the executable.
	engine_dir := filepath.dir(os.args[0])
	main_path, jerr := filepath.join([]string{engine_dir, "main.lua"})
	if jerr != .None {
		fmt.printf("tuicore: filepath.join failed: %v\n", jerr)
		return
	}
	defer delete(main_path)

	main_cstr, cerr := strings.clone_to_cstring(main_path)
	if cerr != .None {
		fmt.printf("tuicore: clone_to_cstring failed: %v\n", cerr)
		return
	}
	defer delete(main_cstr)

	if lua.L_dofile(L, main_cstr) != lua.Status.OK {
		err := lua.tostring(L, -1)
		fmt.printf("Lua load error:\n%s\n", err)
		lua.settop(L, 0)
		return
	}
	lua.settop(L, 0)

	// Lua init.
	if !call_lua_noargs(L, cstring("init_terminal")) { return }

	// Main loop.
	for !rl.WindowShouldClose() {
		frame_t0 := rl.GetTime()

		if rl.IsWindowResized() {
			update_lua_globals(L)
		}

		dt := cast(f64)(rl.GetFrameTime()) // raylib last-frame delta (seconds)

		// Time Lua update.
		u0 := rl.GetTime()
		ok_upd := call_lua_number(L, cstring("update_terminal"), dt)
		u1 := rl.GetTime()
		update_dt := u1 - u0
		if !ok_upd { break }

		// Time Lua draw (CPU time spent in draw_terminal + draw.* callbacks).
		rl.BeginDrawing()
		d0 := rl.GetTime()
		ok_draw := call_lua_noargs(L, cstring("draw_terminal"))
		d1 := rl.GetTime()
		rl.EndDrawing()
		draw_dt := d1 - d0
		if !ok_draw { break }

		frame_t1 := rl.GetTime()
		frame_dt := frame_t1 - frame_t0

		update_perf_test(frame_dt, update_dt, draw_dt)
	}
}

