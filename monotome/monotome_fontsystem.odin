package main

import os  "core:os/os2"
import "core:c"
import "core:fmt"
import "core:strings"
import "vendor:sdl3/ttf"

// TODO(monotome/fontsystem):
//  - Phase 1: Deferred font commits
//      - Right now font changes (Font_Size/Font_Path[0..3]) are only read once
//        at startup via apply_font_changes().
//      - If we ever need live font swaps from Lua (during update()), reintroduce
//        a minimal deferred system:
//          - Fonts_Dirty  : bool
//          - Fonts_Loaded : bool
//          - apply_pending_font_changes() that:
//              - early-outs when !Fonts_Dirty && Fonts_Loaded
//              - rebuilds fonts and recomputes Cell_W/Cell_H when dirty
//          - call apply_pending_font_changes() once per frame between update() and draw().
//        This keeps font+grid changes frame-perfect and avoids mid-frame rebuilds.
//
//  - Phase 2: 1-path "styled" face mode
//      - Current contract: Lua font.init(size, paths4) always supplies 4 full paths
//        (one per face: REG/BOLD/ITALIC/BOLDITALIC).
//      - Future extension: allow font.init(size, { path }) with a single base file:
//          - Introduce: Font_Face_Mode : enum { PATHS, STYLED }
//          - PATHS  => 4 independent Font_Path[i], each opened as-is (current behaviour).
//          - STYLED => Font_Path[0] is the only file; open it 4 times and use SDL_ttf
//                     style flags per face:
//                         face 0: regular (no style)
//                         face 1: bold
//                         face 2: italic
//                         face 3: bold + italic
//                    (SetFontStyle() called once per face after OpenFont, never in draw.)
//        Lua surface would become:
//          - font.init(size, paths4) -> PATHS
//          - font.init(size, { path }) -> STYLED
//
//  - Phase 3: Expose hinting options to Lua (maybe)
//      - Right now hinting is hard-wired inside font loading (e.g. MONO or LIGHT).
//      - If this ever matters visually, expose a tiny Lua API, e.g.:
//          - font.set_hinting("mono" | "light" | "none")
//        and map that to SDL_ttf Hinting enum at font-open time only.
//      - Do not change hinting per-frame or per-glyph; it should be part of the
//        pending font config and applied only in the rebuild path.


//========================================================================================================================================
// GLOBAL FONT STATE
// ...
//========================================================================================================================================
	
Active_Font : [4]^ttf.Font // 0=Regular, 1=Bold, 2=Italic, 3=BoldItalic
Cell_W      : f32
Cell_H      : f32

Font_Size : f32 = 18.0 // point size used for all faces

// Default font file names; we resolve them to:
//   <exe_dir>/fonts/<Default_Font_File[face]>
Default_Font_File : [4]string = {
	"Mononoki-Regular.ttf",
	"Mononoki-Bold.ttf",
	"Mononoki-Italic.ttf",
	"Mononoki-BoldItalic.ttf",
}

Font_Path : [4]string // Host-side font paths as Odin strings ("" = not set)

// ---------------------------------
// SDL TEXT ENGINE STATE
// ---------------------------------

Text_Engine : ^ttf.TextEngine
Text_Cache : [4]map[rune]^ttf.Text // One map per face: key = rune, value = ^ttf.Text

//========================================================================================================================================
// FONT LOADING
// ...
//========================================================================================================================================

// init_font_paths_defaults builds default font paths relative to the exe directory.
init_font_paths_defaults :: proc() {
	exe_dir, err := os.get_executable_directory(context.allocator)
	if err != os.ERROR_NONE {
		panic("init_font_paths_defaults: get_executable_directory failed")
	}

	for face in 0..<4 {
		full_path, _ := os.join_path({exe_dir, "fonts", Default_Font_File[face]}, context.allocator)
		Font_Path[face] = full_path
	}
}

// compute_font_metrics derives Cell_W and Cell_H from face 0 metrics.
compute_font_metrics :: proc() {
	ascent   := ttf.GetFontAscent(Active_Font[0])
	descend  := ttf.GetFontDescent(Active_Font[0])
	height   := ttf.GetFontHeight(Active_Font[0])
	lineskip := ttf.GetFontLineSkip(Active_Font[0]) // baseline-to-baseline

	minx, maxx, miny, maxy, advance: c.int
	ok := ttf.GetGlyphMetrics(Active_Font[0], u32(' '), &minx, &maxx, &miny, &maxy, &advance)
	if !ok {
		panic("compute_font_metrics: GetGlyphMetrics failed for ' '")
	}

	Cell_W = f32(advance)
	Cell_H = f32(height)

	fmt.println("Font metrics (face 0):")
	fmt.println("  ascent   =", ascent)
	fmt.println("  descent  =", descend)
	fmt.println("  height   =", height)
	fmt.println("  lineskip =", lineskip)
	fmt.println("  Cell_W   =", Cell_W)
	fmt.println("  Cell_H   =", Cell_H)
}

/// destroy_text_cache destroys all text object stored in the Text_Cache
destroy_text_cache :: proc() {
	for face in 0..<4 {
		if Text_Cache[face] == nil {
			continue
		}

		for _, txt in Text_Cache[face] {
			if txt != nil {
				ttf.DestroyText(txt)
			}
		}

		delete(Text_Cache[face])
		Text_Cache[face] = nil
	}
}


// apply_font_changes reloads all faces from Font_Path and recomputes grid metrics.
apply_font_changes :: proc() {
	if Font_Size <= 0.0 {
		panic("apply_font_changes: Font_Size must be > 0")
	}

	// Install defaults if paths are not set yet (face 0 as sentinel).
	if len(Font_Path[0]) == 0 {
		init_font_paths_defaults()
	}
	
	// Cached Text objects can hold font-dependent resources.
	// Destroy them before closing/replacing fonts.
	destroy_text_cache()
	// Close any existing fonts.
	for i in 0..<4 {
		if Active_Font[i] != nil {
			ttf.CloseFont(Active_Font[i])
			Active_Font[i] = nil
		}
	}

	// Rebuild fonts from Font_Path[].
	for i in 0..<4 {
		if len(Font_Path[i]) == 0 {
			continue
		}

		path_cstr := strings.clone_to_cstring(Font_Path[i], context.temp_allocator)

		font := ttf.OpenFont(path_cstr, Font_Size)
		if font == nil {
			panic("TTF_OpenFont failed for face")
		}

		// Keep grid honest for monospace.
		ttf.SetFontKerning(font, false)
		
		// Ask SDL_ttf for monochrome/integer-ish hinting.
		ttf.SetFontHinting(font, .LIGHT_SUBPIXEL)

		Active_Font[i] = font
	}

	if Active_Font[0] == nil {
		panic("apply_font_changes: no font loaded in face 0; cannot compute grid")
	}

	compute_font_metrics()
}



