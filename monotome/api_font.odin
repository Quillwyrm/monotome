package main

// api_font.odin
//
// font.* Lua API + host font pipeline.
//
// Lua surface:
// - font.init(pt, paths4?)
// - font.set_paths(paths4)   -- table length must be 4
// - font.set_size(pt)
// - font.size()  -> pt
// - font.paths() -> { [1]=..., [2]=..., [3]=..., [4]=... }  (copy for UI)
//
// Contract:
// - All rendering uses a fixed cell grid derived from face 0 (Regular).
// - All 4 faces bake the SAME codepoint set.
// - No base-vs-regular policy, no styled-face gating, no fallback magic.
// - If a face file is missing a glyph, you get tofu/'?' (this is acceptable).

import lua "luajit"
import rl  "vendor:raylib"

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os/os2"
import "core:strings"

// -----------------------------------------------------------------------------
// Global config/state
// -----------------------------------------------------------------------------

// User-facing font size in pixels.
// This is passed directly to LoadFontEx and DrawText* calls.
Font_Size: c.int = 24

// Faces: 0=Regular, 1=Bold, 2=Italic, 3=BoldItalic.
Active_Font: [4]rl.Font
Fonts_Loaded: bool

// Grid metrics (pixels).
Cell_W: i32
Cell_H: i32

// Legacy hooks for older glyph-atlas draw code paths.
// Kept so old drawing code can still compile; currently always 0.
Cell_Shift_X: i32
Cell_Shift_Y: i32

// Codepoints baked into ALL faces. Built once and reused.
Codepoints: []rune

// Fixed storage for font paths (NUL-terminated for raylib).
MAX_FONT_PATH_BYTES :: 4096

// Default face filenames (relative to exe_dir/fonts/).
Default_Font_File: [4]string = {
	"JetBrainsMono-Regular.ttf",
	"JetBrainsMono-Bold.ttf",
	"JetBrainsMono-Italic.ttf",
	"JetBrainsMono-BoldItalic.ttf",
}

// Runtime path state (single source of truth).
Font_Path_Buf: [4][MAX_FONT_PATH_BYTES]u8
Font_Path_Len: [4]int
Font_Path:     [4]cstring

// -----------------------------------------------------------------------------
// Codepoints (ONE list, baked into all faces)
// -----------------------------------------------------------------------------

Codepoint_Range :: struct {
	first, last: rune, // inclusive
}

// Keep this list tight and intentional.
// If you want NerdFont mega-coverage later, expand here knowingly.
CODEPOINTS: [12]Codepoint_Range = {
	{rune(0x0020), rune(0x007E)}, // Basic Latin (printable ASCII)
	{rune(0x00A0), rune(0x00FF)}, // Latin-1 Supplement
	{rune(0x0100), rune(0x017F)}, // Latin Extended-A

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

// count_ranges returns the total number of codepoints across inclusive ranges.
count_ranges :: proc "contextless" (ranges: []Codepoint_Range) -> int {
	total := 0
	for r in ranges {
		total += cast(int)(r.last - r.first) + 1
	}
	return total
}

// write_ranges expands inclusive ranges into `out` and returns how many runes were written.
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

// build_codepoints allocates and builds the baked codepoint array used by LoadFontEx.
// Requires `context` to be set (allocator needed for make()).
build_codepoints :: proc() -> []rune {
	n := count_ranges(CODEPOINTS[:])
	cps := make([]rune, n)
	_ = write_ranges(cps, CODEPOINTS[:])
	return cps
}

// -----------------------------------------------------------------------------
// Module registration
// -----------------------------------------------------------------------------

// register_font_api registers the tuicore.font Lua module table.
register_font_api :: proc(L: ^lua.State) {
	lua.newtable(L)

	lua.pushcfunction(L, lua_font_init)      ; lua.setfield(L, -2, cstring("init"))
	lua.pushcfunction(L, lua_font_set_paths) ; lua.setfield(L, -2, cstring("set_paths"))
	lua.pushcfunction(L, lua_font_set_size)  ; lua.setfield(L, -2, cstring("set_size"))
	lua.pushcfunction(L, lua_font_size)      ; lua.setfield(L, -2, cstring("size"))
	lua.pushcfunction(L, lua_font_paths)     ; lua.setfield(L, -2, cstring("paths"))

}

// -----------------------------------------------------------------------------
// Public font pipeline entrypoints (host-side)
// -----------------------------------------------------------------------------

// ensure_fonts_loaded makes sure Active_Font[] and cell metrics are ready.
// Safe to call from draw/input subsystems that need fonts.
ensure_fonts_loaded :: proc() {
	if Fonts_Loaded {
		return
	}
	rebuild_fonts()
}

// rebuild_fonts unloads current faces (if any), (re)loads all 4 faces, and recomputes cell metrics.
// This is the only place that should set Fonts_Loaded=true.
rebuild_fonts :: proc() {
	// This proc allocates and uses temp allocators (paths), so ensure context exists.
	context = runtime.default_context()

	unload_active_fonts()

	// If host hasn't installed paths yet, use shipped defaults (exe_dir/fonts/...).
	if Font_Path_Len[0] == 0 {
		init_font_paths_defaults()
	}

	// Build baked codepoint set once (reused on future rebuilds).
	if len(Codepoints) == 0 {
		Codepoints = build_codepoints()
	}

	load_active_fonts(Font_Size, Codepoints)

	compute_cell_metrics()
	validate_monospace_contract()

	Fonts_Loaded = true
	Mouse_Sample_Initialized = false
}

// unload_active_fonts releases the 4 raylib fonts if loaded.
unload_active_fonts :: proc() {
	if !Fonts_Loaded {
		return
	}
	for i in 0..<4 {
		rl.UnloadFont(Active_Font[i])
	}
	Fonts_Loaded = false
}

// -----------------------------------------------------------------------------
// Lua API entrypoints
// -----------------------------------------------------------------------------

// lua_font_init implements: font.init(size [, paths4])
lua_font_init :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	size := cast(c.int)(lua.L_checkinteger(L, 1))
	if size <= 0 {
		return lua.L_error(L, cstring("font.init: size must be > 0"))
	}
	Font_Size = size

	if lua.gettop(L) >= 2 {
		read_paths_and_store(L, 2, cstring("font.init"))
	} else {
		init_font_paths_defaults()
	}

	rebuild_fonts()
	return 0
}


// lua_font_set_paths implements: font.set_paths(paths4)
lua_font_set_paths :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	read_paths_and_store(L, 1, cstring("font.set_paths"))
	rebuild_fonts()
	return 0
}

// lua_font_set_size implements: font.set_size(size)
lua_font_set_size :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	size := cast(c.int)(lua.L_checkinteger(L, 1))
	if size <= 0 {
		return lua.L_error(L, cstring("font.set_size: size must be > 0"))
	}
	Font_Size = size

	rebuild_fonts()
	return 0
}


// lua_font_size implements: font.size() -> size
lua_font_size :: proc "c" (L: ^lua.State) -> c.int {
	lua.pushinteger(L, cast(lua.Integer)(Font_Size))
	return 1
}


// lua_font_paths implements: font.paths() -> { [1]=..., [2]=..., [3]=..., [4]=... }
lua_font_paths :: proc "c" (L: ^lua.State) -> c.int {
	lua.newtable(L)

	for face in 0..<4 {
		p := cast(cstring)(&Font_Path_Buf[face][0])
		lua.pushlstring(L, p, c.size_t(Font_Path_Len[face]))
		lua.rawseti(L, -2, cast(c.int)(face+1))
	}

	return 1
}

// -----------------------------------------------------------------------------
// Path storage helpers (host-side)
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

		set_font_path_bytes(i-1, cast([^]u8)(path_c), int(path_len))
	}
}

// set_font_path_bytes installs a single face path into the fixed host buffer and updates Font_Path[].
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

// init_font_paths_defaults installs exe_dir/fonts/<Default_Font_File[face]> for faces 0..3.
init_font_paths_defaults :: proc() {
	exe_dir, err := os2.get_executable_directory(context.temp_allocator)
	if err != os2.ERROR_NONE {
		panic("init_font_paths_defaults: get_executable_directory failed")
	}

	for face in 0..<4 {
		full_path, jerr := os2.join_path({exe_dir, "fonts", Default_Font_File[face]}, context.temp_allocator)
		if jerr != os2.ERROR_NONE {
			panic("init_font_paths_defaults: join_path failed")
		}

		// clone_to_cstring appends NUL; we copy len(full_path) bytes and then add our own NUL.
		full_path_c := strings.clone_to_cstring(full_path, context.temp_allocator)
		set_font_path_bytes(face, cast([^]u8)(full_path_c), len(full_path))
	}
}

// -----------------------------------------------------------------------------
// Font pipeline internals
// -----------------------------------------------------------------------------


// load_active_fonts loads all 4 faces using the same baked codepoint list,
// and applies POINT+CLAMP to each atlas texture.
load_active_fonts :: proc(font_px: c.int, codepoints: []rune) {
	if len(codepoints) == 0 {
		panic("load_active_fonts: empty codepoint set")
	}

	for i in 0..<4 {
		Active_Font[i] = rl.LoadFontEx(
			Font_Path[i],
			font_px,
			&codepoints[0],
			cast(c.int)(len(codepoints)),
		)
		rl.SetTextureFilter(Active_Font[i].texture, rl.TextureFilter.POINT)
		rl.SetTextureWrap(Active_Font[i].texture, rl.TextureWrap.CLAMP)
	}
}

// compute_cell_metrics defines the grid from the layout face (Regular) ONLY.
// Cell_W comes from SPACE advance; Cell_H comes from font.baseSize.
compute_cell_metrics :: proc() {
	font := Active_Font[0]

	space := rune(' ')
	idx := rl.GetGlyphIndex(font, space)
	g := font.glyphs[idx]

	cell_w := cast(i32)(g.advanceX)

	// If advance is missing, fall back to a width derived from glyph image/rec.
	// (Shouldn't happen in sane monospace fonts, but prevents Cell_W=0.)
	if cell_w <= 0 {
		w := cast(i32)(g.image.width)
		if w <= 0 {
			rec := font.recs[idx]
			w = cast(i32)(rec.width)
		}
		if w <= 0 {
			w = 1
		}
		cell_w = w
	}

	Cell_W = cell_w
	Cell_H = cast(i32)(font.baseSize)

	// No global alignment hacks in this contract.
	Cell_Shift_X = 0
	Cell_Shift_Y = 0
}

// validate_monospace_contract logs (only) suspicious monospace issues:
// - advance != Cell_W for advancing glyphs
// - missing glyphs (g.value != cp)
// It skips advanceX <= 0 to avoid noisy false positives for special spaces, etc.
validate_monospace_contract :: proc() {
	if Cell_W <= 0 {
		return
	}
	if len(Codepoints) == 0 {
		return
	}

	MAX_PRINT :: 16

	missing := [4]int{}
	bad_adv := [4]int{}
	printed := [4]int{}

	for face in 0..<4 {
		font := Active_Font[face]

		for cp in Codepoints {
			i := rl.GetGlyphIndex(font, cp)
			g := font.glyphs[i]

			if g.value != cp {
				missing[face] += 1
				continue
			}

			adv := cast(i32)(g.advanceX)
			if adv <= 0 {
				continue
			}

			if adv != Cell_W {
				bad_adv[face] += 1
				if printed[face] < MAX_PRINT {
					fmt.printf(
						"monotome: face%d advance mismatch U+%04X adv=%d cell=%d\n",
						face, cast(u32)(cp), adv, Cell_W,
					)
					printed[face] += 1
				}
			}
		}
	}

	total_missing := missing[0] + missing[1] + missing[2] + missing[3]
	total_bad_adv := bad_adv[0] + bad_adv[1] + bad_adv[2] + bad_adv[3]

	if total_missing > 0 || total_bad_adv > 0 {
		fmt.printf(
			"monotome: font contract warnings: missing=%d bad_adv=%d (cell_w=%d)\n",
			total_missing, total_bad_adv, Cell_W,
		)
	}
}

