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

import lua     "luajit"
import runtime "base:runtime"
import c       "core:c"

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

	rebuild_fonts(L)
	return 0
}

// font.set_paths(paths4)
lua_font_set_paths :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	read_paths_and_store(L, 1, cstring("font.set_paths"))
	rebuild_fonts(L)
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
	rebuild_fonts(L)
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

