package main

import "base:runtime"
import "core:mem"	
import "core:fmt"
import "core:strings"
import "core:c"
import os  "core:os/os2"
import sdl "vendor:sdl3"
import lua "luajit"

//========================================================================================================================================
// CORE ENGINE STATE
//========================================================================================================================================

Window   : ^sdl.Window
Renderer : ^sdl.Renderer
Lua 		 : ^lua.State

//========================================================================================================================================
// LUA EMBEDDING HELPERS
//========================================================================================================================================

// register_lua_api builds the global `monotome` table with runtime/draw/font/window sub-tables.
register_lua_api :: proc() {
	// root table: monotome
	lua.newtable(Lua) // stack: [monotome]

	// monotome.runtime = {}
	lua.newtable(Lua)                         // stack: [monotome, runtime]
	lua.setfield(Lua, -2, cstring("runtime")) // monotome.runtime = runtime; stack: [monotome]

	// monotome.draw = {}
	register_draw_api(Lua)                    // stack: [monotome, draw]
	lua.setfield(Lua, -2, cstring("draw"))    // monotome.draw = draw; stack: [monotome]

	// monotome.font = {}
	register_font_api(Lua)                    // stack: [monotome, font]
	lua.setfield(Lua, -2, cstring("font"))    // monotome.font = font; stack: [monotome]

	// monotome.window = {}
	register_window_api(Lua)                  // stack: [monotome, window]
	lua.setfield(Lua, -2, cstring("window"))  // monotome.window = window; stack: [monotome]
	
	// monotome.input = {}
	register_input_api(Lua)                 	// stack: [monotome, input]
	lua.setfield(Lua, -2, cstring("input"))	 // monotome.input = input; stack: [monotome]

	// Global: monotome = <that table>
	lua.setglobal(Lua, cstring("monotome"))   // pops table; stack: []
}

// lua_traceback is the error handler for lua.pcall; it converts an error into a traceback string.
lua_traceback :: proc "c" (L: ^lua.State) -> c.int {
	msg := lua.tostring(L, 1)
	if msg == nil {
		msg = cstring("Lua error")
	}
	lua.L_traceback(L, L, msg, 1)
	return 1
}

// call_lua_noargs calls monotome.runtime[fn]() and prints any Lua error.
call_lua_noargs :: proc(fn: cstring) -> bool {
	lua.pushcfunction(Lua, lua_traceback)
	errfunc := lua.gettop(Lua)

	// Lookup: monotome.runtime[fn]
	lua.getglobal(Lua, cstring("monotome"))    // [errfunc, monotome]
	lua.getfield(Lua, -1, cstring("runtime")) // [errfunc, monotome, runtime]
	lua.getfield(Lua, -1, fn)                 // [errfunc, monotome, runtime, runtime[fn]]

	ok := lua.pcall(Lua, 0, 0, cast(c.int)(errfunc)) == lua.Status.OK
	if !ok {
		err := lua.tostring(Lua, -1)
		fmt.printf("Lua error in monotome.runtime.%s:\n%s\n", fn, err)
	}

	lua.settop(Lua, 0)
	return ok
}

// call_lua_number calls monotome.runtime[fn](x: number) and prints any Lua error.
call_lua_number :: proc(fn: cstring, x: f64) -> bool {
	lua.pushcfunction(Lua, lua_traceback)
	errfunc := lua.gettop(Lua)

	// Lookup: monotome.runtime[fn]
	lua.getglobal(Lua, cstring("monotome"))
	lua.getfield(Lua, -1, cstring("runtime"))
	lua.getfield(Lua, -1, fn)

	lua.pushnumber(Lua, cast(lua.Number)(x))

	ok := lua.pcall(Lua, 1, 0, cast(c.int)(errfunc)) == lua.Status.OK
	if !ok {
		err := lua.tostring(Lua, -1)
		fmt.printf("Lua error in monotome.runtime.%s:\n%s\n", fn, err)
	}

	lua.settop(Lua, 0)
	return ok
}

//========================================================================================================================================
// MAIN RUNTIME ENTRY
//========================================================================================================================================
main :: proc() {
	context = runtime.default_context()

	// ---------------------------------------------------------------------
	// SDL
	// ---------------------------------------------------------------------
	if !sdl.Init({.VIDEO}) {
		fmt.eprintln("SDL_Init failed:", sdl.GetError())
		return
	}
	defer sdl.Quit()

	// ---------------------------------------------------------------------
	// Lua: load main.lua and run runtime.init()
	// ---------------------------------------------------------------------
	Lua = lua.L_newstate()
	if Lua == nil {
		fmt.eprintln("Lua L_newstate failed")
		return
	}
	defer lua.close(Lua)

	lua.L_openlibs(Lua)
	register_lua_api()

	exe_dir, err := os.get_executable_directory(context.temp_allocator)
	if err != os.ERROR_NONE {
		fmt.eprintln("get_executable_directory failed:", err)
		return
	}

	main_path, err2 := os.join_path({exe_dir, "lua", "main.lua"}, context.temp_allocator)
	if err2 != os.ERROR_NONE {
		fmt.eprintln("join_path for main.lua failed:", err2)
		return
	}

	main_path_c := strings.clone_to_cstring(main_path, context.temp_allocator)

	if lua.L_dofile(Lua, main_path_c) != lua.Status.OK {
		lua_err := lua.tostring(Lua, -1)
		fmt.printf("Lua load error:\n%s\n", lua_err)
		lua.settop(Lua, 0)
		return
	}
	lua.settop(Lua, 0)

	mem.free_all(context.temp_allocator)

	if !call_lua_noargs(cstring("init")) {
		return
	}

	mem.free_all(context.temp_allocator)

	// runtime.init() must call monotome.window.init(...)
	if Window == nil || Renderer == nil {
		fmt.eprintln("runtime.init() did not call monotome.window.init(...)")
		return
	}

	// Hard-set VSync for now.
	if !sdl.SetRenderVSync(Renderer, 1) {
		fmt.eprintln("VSync failed:", sdl.GetError())
	}

	// Window/module owns window teardown. Host calls once.
	defer window_shutdown()

	// ---------------------------------------------------------------------
	// Input
	// ---------------------------------------------------------------------
	input_init()
	defer input_shutdown()

	// ---------------------------------------------------------------------
	// Timing
	// ---------------------------------------------------------------------
	perf_freq    := f64(sdl.GetPerformanceFrequency())
	last_counter := sdl.GetPerformanceCounter()

	// ---------------------------------------------------------------------
	// Event loop
	// ---------------------------------------------------------------------
	event: sdl.Event
	running := true

	for running {
		input_begin_frame()

		for sdl.PollEvent(&event) {
			if event.type == .QUIT || event.type == .WINDOW_CLOSE_REQUESTED {
				Quit_Requested = true
			}
			input_handle_event(&event)
		}

		input_end_frame()

		now_counter := sdl.GetPerformanceCounter()
		delta_ticks := now_counter - last_counter
		last_counter = now_counter
		dt := f64(delta_ticks) / perf_freq

		if !call_lua_number(cstring("update"), dt) {
			break
		}

		// Commit any font changes requested during update() before drawing.
		apply_font_changes()

		if !call_lua_noargs(cstring("draw")) {
			break
		}

		sdl.RenderPresent(Renderer)

		if Quit_Requested {
			running = false
		}

		mem.free_all(context.temp_allocator)
	}
}

