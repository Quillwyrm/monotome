package main

// monotome — Lua-scriptable cell-space renderer (textmode look) backed by raylib.
// Lua must define: init_terminal(), update_terminal(dt), draw_terminal().
//
// Exposes to Lua modules:
// - draw:   clear, cell, rect, glyph, text
// - window: init/config + metrics (render_size, cell_size, grid_size, etc.)
// - input:  keyboard/mouse polling + typed text (cell-space only)
// - font:   font paths + point size (regular/bold/italic/bold-italic)
//
// Rendering notes:
// - All drawing is in *cell coordinates*; pixels are never exposed to Lua.
// - draw.glyph uses only the first UTF-8 codepoint from `text`.
// - Glyph quads are clipped to the destination cell rectangle.


import rl       "vendor:raylib"
import lua      "luajit"
import os       "core:os"
import fmt      "core:fmt"
import strings  "core:strings"
import filepath "core:path/filepath"
import c        "core:c"

// -----------------------------------------------------------------------------
// Lua globals + API binding
// -----------------------------------------------------------------------------


push_lua_module :: proc(L: ^lua.State, module_name: cstring) {
	// Stack on entry: [module_table]
	
	lua.getglobal(L, cstring("package"))         // [module_table, package]
	lua.getfield(L, -1, cstring("loaded"))       // [module_table, package, loaded]
	
	lua.pushvalue(L, -3)                         // [module_table, package, loaded, module_table]
	lua.setfield(L, -2, module_name)             // loaded[module_name] = module_table (pops copy)
	
	
	
	lua.pop(L, 3)                                // pop loaded, package, module_table -> []
}

// register_lua_api registers the Lua module tables (draw/window/input/font).
// Grid/cell dimensions are queried at runtime via window.grid_size()/window.cell_size()
// once fonts are loaded (Cell_W/Cell_H computed by the font pipeline).
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
// main
// -----------------------------------------------------------------------------

// main boots Lua, loads main.lua, calls init_terminal(), loads fonts/cell metrics,
// then runs the update/draw loop (including input_begin_frame() once per frame).
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
	ensure_fonts_loaded()
	defer unload_active_fonts()

	// -------------------------------------------------------------------------
	// Main loop
	// -------------------------------------------------------------------------
	for !rl.WindowShouldClose() {


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

