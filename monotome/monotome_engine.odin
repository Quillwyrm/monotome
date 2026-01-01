package main

import "base:runtime"
import "core:mem"	
import "core:fmt"
import "core:strings"
import "core:c"
import os  "core:os/os2"
import sdl "vendor:sdl3"
import "vendor:sdl3/ttf"
import lua "luajit"

//========================================================================================================================================
// CORE ENGINE STATE
// ...
//========================================================================================================================================

Window   : ^sdl.Window
Renderer : ^sdl.Renderer
Lua 		 : ^lua.State

//========================================================================================================================================
// LUA EMBEDDING HELPERS
// ...
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
// ...
//========================================================================================================================================

// main boots SDL, Lua, and the text engine, then runs the perf-counter-driven loop.
main :: proc() {
	//set default context for this scope
	context = runtime.default_context()
	
	// SDL init.
	if !sdl.Init({.VIDEO}) {
		fmt.eprintln("SDL_Init failed:", sdl.GetError())
		return
	}
	defer sdl.Quit()

	// Window and renderer will be created from Lua via window.init(...).
	defer sdl.DestroyWindow(Window)
	defer sdl.DestroyRenderer(Renderer)


	// Cleanup: text cache, text engine, fonts.
	defer {
		// Destroy cached Text objects.
		destroy_text_cache()

		// Destroy text engine.
		if Text_Engine != nil {
			ttf.DestroyRendererTextEngine(Text_Engine)
			Text_Engine = nil
		}

		// Close fonts.
		for i in 0..<4 {
			if Active_Font[i] != nil {
				ttf.CloseFont(Active_Font[i])
				Active_Font[i] = nil
			}
		}
	}

	// -----------------------------
	// Lua state + main.lua
	// -----------------------------
	Lua = lua.L_newstate()
	if Lua == nil {
		fmt.eprintln("Lua L_newstate failed")
		return
	}
	defer lua.close(Lua)

	lua.L_openlibs(Lua)
	register_lua_api() // sets global `monotome` with .runtime, .draw, .window, .input (you did the rest)

	// Resolve <exe_dir>/main.lua
	exe_dir, err := os.get_executable_directory(context.allocator)
	if err != os.ERROR_NONE {
		fmt.eprintln("get_executable_directory failed:", err)
		return
	}

	main_path, err2 := os.join_path({exe_dir, "main.lua"}, context.allocator)
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
	
	// Lua init: monotome.runtime.init() should call monotome.window.init(...).
	if !call_lua_noargs(cstring("init")) {
		return
	}
	
	mem.free_all(context.temp_allocator)


	if Window == nil || Renderer == nil {
		fmt.eprintln("runtime.init() did not call monotome.window.init(...)")
		return
	}

	// -----------------------------
	// INPUT INIT (Phase 1)
	// -----------------------------
	input_init()

	// TTF init (now that Renderer exists).
	if !ttf.Init() {
		fmt.eprintln("TTF_Init failed:", sdl.GetError())
		return
	}
	defer ttf.Quit()

	// Font backend setup (loads fonts, computes Cell_W/Cell_H, clears text cache if needed).
	apply_font_changes()

	// Text engine bound to global Renderer.
	Text_Engine = ttf.CreateRendererTextEngine(Renderer)
	if Text_Engine == nil {
		fmt.eprintln("CreateRendererTextEngine failed")
		return
	}

	// -----------------------------
	// High-resolution timing setup (seconds).
	// -----------------------------
	perf_freq    := f64(sdl.GetPerformanceFrequency())
	last_counter := sdl.GetPerformanceCounter()

	// -----------------------------
	// Event loop.
	// -----------------------------
	event: sdl.Event
	running := true

	for running {
		// Phase 1 input: clear per-frame edges before polling.
		input_begin_frame()

		for sdl.PollEvent(&event) {
			// Phase 1 input: feed every event.
			input_handle_event(&event)

			if event.type == .QUIT {
				running = false
			}
		}
		if !running {
			break
		}

		// Phase 1 input: sample final mouse state for this frame.
		input_end_frame()

		// Real dt in seconds using SDL's performance counter.
		now_counter := sdl.GetPerformanceCounter()
		delta_ticks := now_counter - last_counter
		last_counter = now_counter

		dt := f64(delta_ticks) / perf_freq

		// Lua update(dt)
		if !call_lua_number(cstring("update"), dt) {
			break
		}

		// Lua draw()
		if !call_lua_noargs(cstring("draw")) {
			break
		}
		//present renderer frame content
		sdl.RenderPresent(Renderer)
		
		//free all allocations on the default context temp_allocator
		mem.free_all(context.temp_allocator)
	}
}

