package main

// lua_font.odin
//
// font.* Lua API (font paths + size), backed by the host font pipeline.
//
// Lua surface:
// - font.init(pt, paths4)
// - font.set_paths(paths4)   -- requires exactly 4 strings, 1..4
// - font.set_size(pt)
// - font.size()  -> pt
// - font.paths() -> { [1]=..., [2]=..., [3]=..., [4]=... }  (copy for UI)

import lua "luajit"
import rl  "vendor:raylib"
import 	  "base:runtime"
import     "core:c"

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
// Registration
// -----------------------------------------------------------------------------

register_font_api :: proc(L: ^lua.State) {
	lua.newtable(L)

	lua.pushcfunction(L, lua_font_init)      ; lua.setfield(L, -2, cstring("init"))
	lua.pushcfunction(L, lua_font_set_paths) ; lua.setfield(L, -2, cstring("set_paths"))
	lua.pushcfunction(L, lua_font_set_size)  ; lua.setfield(L, -2, cstring("set_size"))

	lua.pushcfunction(L, lua_font_size)      ; lua.setfield(L, -2, cstring("size"))
	lua.pushcfunction(L, lua_font_paths)     ; lua.setfield(L, -2, cstring("paths"))

	push_lua_module(L, cstring("tuicore.font"))
}

// -----------------------------------------------------------------------------
// Internal helpers
// -----------------------------------------------------------------------------

// read_paths_and_store copies Lua table paths[1..4] into the fixed host buffers.
read_paths_and_store :: proc(L: ^lua.State, idx: lua.Index, who: cstring) {
	lua.L_checktype(L, cast(c.int)(idx), lua.Type.TABLE)

	n := int(lua.objlen(L, idx))
	if n != 4 {
		lua.L_error(L, cstring("%s: expected paths table of length 4 (got %d)"), who, n)
		return
	}

	for i in 1..=4 {
		lua.rawgeti(L, idx, cast(lua.Integer)(i))

		path_len: c.size_t
		path_c := lua.L_checklstring(L, -1, &path_len)
		lua.pop(L, 1)

		if path_len == 0 {
			lua.L_error(L, cstring("%s: paths[%d] must be a non-empty string"), who, i)
			return
		}

		// Copy bytes into host-owned fixed buffer (adds NUL terminator).
		set_font_path_bytes(i-1, cast([^]u8)(path_c), int(path_len))
	}
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

rebuild_fonts :: proc() {
	unload_active_fonts()

	font_px := compute_font_px()
	load_active_fonts(font_px, Base_Codepoints, Regular_Codepoints, Regular_Written)
	compute_cell_metrics()
	Fonts_Loaded = true
	Mouse_Sample_Initialized = false

}

ensure_fonts_loaded :: proc() {
	if Fonts_Loaded {
		return
	}
	rebuild_fonts()
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
// Lua API
// -----------------------------------------------------------------------------

// font.init(pt, paths4)
lua_font_init :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	pt := cast(c.int)(lua.L_checkinteger(L, 1))
	if pt <= 0 {
		return lua.L_error(L, cstring("font.init: pt must be > 0"))
	}

	Font_Pt = pt
	read_paths_and_store(L, 2, cstring("font.init"))

	rebuild_fonts()
	return 0
}

// font.set_paths(paths4)
lua_font_set_paths :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	read_paths_and_store(L, 1, cstring("font.set_paths"))
	rebuild_fonts()
	return 0
}

// font.set_size(pt)
lua_font_set_size :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	pt := cast(c.int)(lua.L_checkinteger(L, 1))
	if pt <= 0 {
		return lua.L_error(L, cstring("font.set_size: pt must be > 0"))
	}

	Font_Pt = pt
	rebuild_fonts()
	return 0
}

// font.size() -> pt
lua_font_size :: proc "c" (L: ^lua.State) -> c.int {
	lua.pushinteger(L, cast(lua.Integer)(Font_Pt))
	return 1
}

// font.paths() -> table copy
lua_font_paths :: proc "c" (L: ^lua.State) -> c.int {
	lua.newtable(L)

	for face in 0..<4 {
		p := cast(cstring)(&Font_Path_Buf[face][0])
		lua.pushlstring(L, p, c.size_t(Font_Path_Len[face]))
		lua.rawseti(L, -2, cast(c.int)(face+1))
	}

	return 1
}

