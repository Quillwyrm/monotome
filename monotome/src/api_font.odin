package main

import "base:runtime"
import "core:c"
import "core:strings"
import lua "luajit"

// ---------------------------------
// Lua font API: monotome.font.*
// ---------------------------------

// read_font_paths4 copies a Lua table[1..4] of strings into Font_Path[0..3].
// Expected shape:
//   paths4[1] -> regular
//   paths4[2] -> bold
//   paths4[3] -> italic
//   paths4[4] -> bold-italic
read_font_paths4 :: proc(L: ^lua.State, idx: lua.Index) {
	context = runtime.default_context()

	lua.L_checktype(L, cast(c.int)(idx), lua.Type.TABLE)

	paths_len := int(lua.objlen(L, idx))
	if paths_len != 4 {
		lua.L_error(L, cstring("font: paths table must contain exactly 4 string entries"))
		return
	}

	i: lua.Integer = 1
	for face in 0..<4 {
		lua.rawgeti(L, idx, i) // push paths[i]

		if lua.type(L, -1) != lua.Type.STRING {
			lua.L_error(L, cstring("font: all paths entries must be strings"))
			return
		}

		path_len: c.size_t
		path_c  := lua.L_checklstring(L, -1, &path_len)
		lua.pop(L, 1)

		if path_len == 0 {
			lua.L_error(L, cstring("font: paths entries must be non-empty strings"))
			return
		}

		// Free previous path to avoid leaking when reloading fonts at runtime.
		if len(Font_Path[face]) != 0 {
			delete(Font_Path[face])
			Font_Path[face] = ""
		}

		s := strings.string_from_ptr(cast(^byte)(path_c), int(path_len))
		Font_Path[face] = strings.clone(s, context.allocator)

		i += 1
	}
}


// monotome.font.init(size_px, paths4)
// size_px : Lua number > 0
// paths4  : table[1..4] of full/relative file paths (reg, bold, italic, bold-italic)
lua_font_init :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	nargs := lua.gettop(L)
	if nargs < 2 {
		lua.L_error(L, cstring("font.init expects 2 arguments: size, paths4 table"))
		return 0
	}

	size := lua.L_checknumber(L, 1)
	if size <= 0.0 {
		lua.L_error(L, cstring("font.init: size must be > 0"))
		return 0
	}
	Font_Size = f32(size)

	if lua.type(L, 2) != lua.Type.TABLE {
		lua.L_error(L, cstring("font.init: second argument must be a table of 4 string paths"))
		return 0
	}

	read_font_paths4(L, lua.Index(2))

	Fonts_Dirty = true
	return 0
}

// monotome.font.set_size(size_px)
// Adjusts Font_Size only. In the current engine this must be
// called before the first apply_font_changes() to take effect.
lua_font_set_size :: proc "c" (L: ^lua.State) -> c.int {
	nargs := lua.gettop(L)
	if nargs < 1 {
		lua.L_error(L, cstring("font.set_size expects 1 argument: size"))
		return 0
	}

	size := lua.L_checknumber(L, 1)
	if size <= 0.0 {
		lua.L_error(L, cstring("font.set_size: size must be > 0"))
		return 0
	}

	Font_Size = f32(size)
	Fonts_Dirty = true
	return 0
}


// monotome.font.load(paths4)
// Replaces Font_Path[0..3] but does not change Font_Size.
lua_font_load :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	if lua.gettop(L) < 1 {
		lua.L_error(L, cstring("font.load expects 1 argument: paths4 table"))
		return 0
	}

	if lua.type(L, 1) != lua.Type.TABLE {
		lua.L_error(L, cstring("font.load: argument must be a table of 4 string paths"))
		return 0
	}

	read_font_paths4(L, lua.Index(1))

	Fonts_Dirty = true
	return 0
}


// local size = monotome.font.size()
lua_font_size :: proc "c" (L: ^lua.State) -> c.int {
	lua.pushnumber(L, lua.Number(Font_Size))
	return 1
}

// local paths4 = monotome.font.paths()
//
// Returns a new table[1..4] of the current Font_Path[0..3].
// In the fallback case where defaults are in use and apply_font_changes()
// has not installed them yet, this may be empty strings.
lua_font_paths :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	lua.newtable(L) // result table

	for face in 0..<4 {
		if len(Font_Path[face]) == 0 {
			continue
		}

		path := Font_Path[face]
		lua.pushlstring(L, cstring(raw_data(path)), c.size_t(len(path)))
		lua.rawseti(L, -2, c.int(face+1))

	}

	return 1
}

// register_font_api creates the monotome.font table and registers font.* procs.
register_font_api :: proc(L: ^lua.State) {
	lua.newtable(L) // [font]

	lua.pushcfunction(L, lua_font_init)
	lua.setfield(L, -2, cstring("init"))

	lua.pushcfunction(L, lua_font_set_size)
	lua.setfield(L, -2, cstring("set_size"))

	lua.pushcfunction(L, lua_font_load)
	lua.setfield(L, -2, cstring("load"))

	lua.pushcfunction(L, lua_font_size)
	lua.setfield(L, -2, cstring("size"))

	lua.pushcfunction(L, lua_font_paths)
	lua.setfield(L, -2, cstring("paths"))
}

