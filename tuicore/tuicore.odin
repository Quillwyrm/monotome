package main

// tuicore — prototype terminal grid renderer driven by Lua.
// Lua must define: init_terminal(), update_terminal(dt), draw_terminal().
//
// Exposes to Lua:
// - draw.clear(rgba), draw.cell(x,y,rgba), draw.glyph(x,y,rgba,text,face)
// - window.* (see api_window.odin)
// - globals: TERM_COLS, TERM_ROWS
//
// Rendering notes:
// - draw.glyph uses only the first UTF-8 codepoint from `text`.
// - Glyph quads are clipped to the cell rectangle.

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
Font_Pt: c.int = 24

// Internal raster size passed to LoadFontEx (computed at startup).
Font_Px: c.int

// Face order: 0=Regular, 1=Bold, 2=Italic, 3=BoldItalic.

// Fixed storage for font paths (NUL-terminated for raylib).
MAX_FONT_PATH_BYTES :: 4096

// Defaults (used if Lua does not call font.init/set_paths before first load).
Default_Font_Path: [4]cstring = {

	cstring("C:\\dev\\dev_tuicore\\tuicore\\fonts\\JetBrainsMono-Regular.ttf"),
	cstring("C:\\dev\\dev_tuicore\\tuicore\\fonts\\JetBrainsMono-Bold.ttf"),
	cstring("C:\\dev\\dev_tuicore\\tuicore\\fonts\\JetBrainsMono-Italic.ttf"),
	cstring("C:\\dev\\dev_tuicore\\tuicore\\fonts\\JetBrainsMono-BoldItalic.ttf"),
}


// Runtime path state (single source of truth).
Font_Path_Buf: [4][MAX_FONT_PATH_BYTES]u8
Font_Path_Len: [4]int
Font_Path: [4]cstring

Active_Font: [4]rl.Font
Fonts_Loaded: bool

// Prebuilt codepoint lists (allocated once; reused on rebuild).
Base_Codepoints: []rune
Regular_Codepoints: []rune
Regular_Written: int
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

push_lua_module :: proc(L: ^lua.State, module_name: cstring) {
	// Stack on entry: [module_table]

	lua.getglobal(L, cstring("package"))         // [module_table, package]
	lua.getfield(L, -1, cstring("loaded"))       // [module_table, package, loaded]

	lua.pushvalue(L, -3)                         // [module_table, package, loaded, module_table]
	lua.setfield(L, -2, module_name)             // loaded[module_name] = module_table (pops copy)

	lua.pop(L, 3)                                // pop loaded, package, module_table -> []
}

// register_lua_api registers Lua tables/functions (no size-dependent globals).
// Call update_lua_globals(L) after the window + Cell_W/Cell_H are ready.
register_lua_api :: proc(L: ^lua.State) {
	register_draw_api(L)
	register_window_api(L)
	register_input_api(L)
	register_font_api(L)
}

// -----------------------------------------------------------------------------
// Lua errors + call helpers
// -----------------------------------------------------------------------------

// lua_traceback is the error handler for lua.pcall; it converts an error into a traceback string.
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
	errfunc := lua.gettop(L)

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
// Font pipeline helpers
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// Font config storage (paths) + rebuild orchestration
// -----------------------------------------------------------------------------

set_font_path_bytes :: proc(face: int, p: [^]u8, n: int) {
	if face < 0 || face > 3 {
		panic("set_font_path_bytes: face out of range")
	}
	if n <= 0 {
		panic("set_font_path_bytes: empty path")
	}
	if n >= MAX_FONT_PATH_BYTES {
		panic("set_font_path_bytes: path too long for fixed buffer")
	}

	for i in 0..<n {
		Font_Path_Buf[face][i] = p[i]
	}
	Font_Path_Buf[face][n] = 0
	Font_Path_Len[face] = n
	Font_Path[face] = cast(cstring)(&Font_Path_Buf[face][0])
}

init_font_paths_defaults :: proc() {
	for face in 0..<4 {
		src := cast([^]u8)(Default_Font_Path[face])

		n := 0
		for n < MAX_FONT_PATH_BYTES-1 {
			b := src[n]
			if b == 0 {
				break
			}
			Font_Path_Buf[face][n] = b
			n += 1
		}
		Font_Path_Buf[face][n] = 0
		Font_Path_Len[face] = n
		Font_Path[face] = cast(cstring)(&Font_Path_Buf[face][0])
	}
}

unload_active_fonts :: proc() {
	if !Fonts_Loaded {
		return
	}
	for i in 0..<4 {
		rl.UnloadFont(Active_Font[i])
	}
	Fonts_Loaded = false
}

rebuild_fonts :: proc(L: ^lua.State) {
	unload_active_fonts()

	font_px := compute_font_px()
	load_active_fonts(font_px, Base_Codepoints, Regular_Codepoints, Regular_Written)
	compute_cell_metrics()
	Fonts_Loaded = true

	update_lua_globals(L)
}

ensure_fonts_loaded :: proc(L: ^lua.State) {
	if Fonts_Loaded {
		return
	}
	rebuild_fonts(L)
}

// compute_font_px converts UI points (Font_Pt) into a pixel size used by LoadFontEx.
// Also writes Font_Px.
compute_font_px :: proc() -> c.int {
	dpi := rl.GetWindowScaleDPI()
	scale := dpi[0]

	px_f := cast(f32)(Font_Pt) * (4.0 / 3.0) * scale
	px := cast(c.int)(px_f + 0.5)

	Font_Px = px
	return px
}

// build_codepoint_lists expands the baked range lists into rune arrays for LoadFontEx.
// Face 0 gets BASE_CODEPOINTS + REGULAR_CODEPOINTS; faces 1..3 get BASE_CODEPOINTS.
build_codepoint_lists :: proc() -> (base_codepoints: []rune, regular_codepoints: []rune, regular_written: int) {
	base_count := count_ranges(BASE_CODEPOINTS[:])
	reg_count  := count_ranges(REGULAR_CODEPOINTS[:])

	base_codepoints = make([]rune, base_count)
	_ = write_ranges(base_codepoints, BASE_CODEPOINTS[:])

	regular_codepoints = make([]rune, base_count + reg_count)
	regular_written = 0
	regular_written += write_ranges(regular_codepoints[regular_written:], BASE_CODEPOINTS[:])
	regular_written += write_ranges(regular_codepoints[regular_written:], REGULAR_CODEPOINTS[:])

	return
}

// load_active_fonts loads the 4 font faces and applies POINT/CLAMP texture policy.
load_active_fonts :: proc(font_px: c.int, base_codepoints: []rune, regular_codepoints: []rune, regular_written: int) {
	Active_Font[0] = rl.LoadFontEx(
		Font_Path[0],
		font_px,
		&regular_codepoints[0],
		cast(c.int)(regular_written),
	)
	rl.SetTextureFilter(Active_Font[0].texture, rl.TextureFilter.POINT)
	rl.SetTextureWrap(Active_Font[0].texture, rl.TextureWrap.CLAMP)

	for i in 1..<4 {
		Active_Font[i] = rl.LoadFontEx(
			Font_Path[i],
			font_px,
			&base_codepoints[0],
			cast(c.int)(len(base_codepoints)),
		)
		rl.SetTextureFilter(Active_Font[i].texture, rl.TextureFilter.POINT)
		rl.SetTextureWrap(Active_Font[i].texture, rl.TextureWrap.CLAMP)
	}
}

// compute_cell_metrics computes Cell_W/Cell_H from the active regular font.
// Width uses max ASCII advance; height uses font baseSize.
compute_cell_metrics :: proc() {
	max_adv: c.int = 1
	for cp := rune(32); cp <= rune(126); cp += 1 {
		adv := rl.GetGlyphInfo(Active_Font[0], cp).advanceX
		if adv > max_adv {
			max_adv = adv
		}
	}

	Cell_W = cast(i32)(max_adv)
	Cell_H = cast(i32)(Active_Font[0].baseSize)
	// Invariant: Cell_H > 0 by construction (font baseSize expected > 0).
}

// -----------------------------------------------------------------------------
// main
// -----------------------------------------------------------------------------

// main boots Lua, runs init, loads fonts, publishes TERM_COLS/ROWS, and runs the update/draw loop.
main :: proc() {
	// -------------------------------------------------------------------------
	// Lua state + script load
	// -------------------------------------------------------------------------
	L := lua.L_newstate()
	defer lua.close(L)
	lua.L_openlibs(L)

	register_lua_api(L)

	init_font_paths_defaults()
	Base_Codepoints, Regular_Codepoints, Regular_Written = build_codepoint_lists()

	rl.SetTraceLogLevel(rl.TraceLogLevel.ERROR)



	exe_dir := filepath.dir(os.args[0])
	main_path, err := filepath.join([]string{exe_dir, "main.lua"})
	if err != nil {
		fmt.printf("join error:\n%s\n", err)
		return
	}
	main_path_c := strings.clone_to_cstring(main_path, context.temp_allocator)

	if lua.L_dofile(L, main_path_c) != lua.Status.OK {
		lua_err := lua.tostring(L, -1)
		fmt.printf("Lua load error:\n%s\n", lua_err)
		lua.settop(L, 0)
		return
	}
	lua.settop(L, 0)

	// Lua init must create the window (window.init).
	if !call_lua_noargs(L, cstring("init_terminal")) {
		return
	}
	defer rl.CloseWindow()

	// -------------------------------------------------------------------------
	// Font + cell metrics (needs window)
	// -------------------------------------------------------------------------
	ensure_fonts_loaded(L)
	defer unload_active_fonts()

	// -------------------------------------------------------------------------
	// Main loop
	// -------------------------------------------------------------------------
	for !rl.WindowShouldClose() {

		if rl.IsWindowResized() {
			update_lua_globals(L)
		}

		// last-frame delta (seconds)
		dt_s := cast(f64)(rl.GetFrameTime())

		// refresh per-frame input caches (typed text)
		input_begin_frame()

		// --- Lua update ---
		if !call_lua_number(L, cstring("update_terminal"), dt_s) {
			break
		}

		// --- Lua draw ---
		rl.BeginDrawing()
		if !call_lua_noargs(L, cstring("draw_terminal")) {
			rl.EndDrawing()
			break
		}
		rl.EndDrawing()
	}
}

