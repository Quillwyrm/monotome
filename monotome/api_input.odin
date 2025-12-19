package main

// lua_input.odin
//
// input.* Lua API (keyboard + mouse), backed by raylib.
//
// Core constraint: the Lua input surface is CELL-SPACE ONLY.
// - Mouse position and mouse delta are expressed in TERMINAL CELL coordinates (ints).
// - Raylib provides pixels internally; Lua never sees pixels.
//
// Lua surface (strings-only tokens):
// - Keyboard: key_down, key_up, key_pressed, key_released, key_repeat
// - Text:     get_text() -> string (all UTF-8 typed this frame)
// - Mouse:    mouse_down, mouse_up, mouse_pressed, mouse_released
// - Mouse:    mouse_pos()   -> cx,  cy   (cell ints)
// - Mouse:    mouse_delta() -> dcx, dcy  (cell ints; since last frame)
// - Mouse:    mouse_wheel() -> dx,  dy   (wheel units; numbers)
//
// Token rules (canonical, no aliases):
// - Letters/digits: "a".."z", "0".."9"
// - Punctuation:    literal tokens:  ' , - . / ; = [ \ ] `
// - Named keys:      esc, enter, tab, space, backspace,
//                   ins, del, home, end, pgup, pgdn,
//                   up, down, left, right,
//                   capslock, numlock, scrolllock, prtsc, pause,
//                   f1..f12,
//                   lshift, rshift, lctrl, rctrl, lalt, ralt, lsuper, rsuper,
//                   menu,
//                   numpad0..numpad9, numpad., numpad/, numpad*, numpad-, numpad+, numpadenter, numpad=
//
// Host requirement:
// - Call input_begin_frame() once per frame (before Lua update) to refresh per-frame caches.
// - Cell_W / Cell_H must be initialized by the host (pixel size of one terminal cell).

import rl      "vendor:raylib"
import lua     "luajit"
import strings "core:strings"
import runtime "base:runtime"
import c       "core:c"


// -----------------------------------------------------------------------------
// Consts
// -----------------------------------------------------------------------------

// INPUT_TEXT_CAP is the maximum UTF-8 bytes captured for "typed this frame".
INPUT_TEXT_CAP :: 4096


// -----------------------------------------------------------------------------
// State (host-driven per-frame caches)
// -----------------------------------------------------------------------------

// Input_Text_Buf stores UTF-8 bytes typed this frame (from raylib GetCharPressed()).
Input_Text_Buf: [INPUT_TEXT_CAP]u8
// Input_Text_Len is the number of valid bytes in Input_Text_Buf.
Input_Text_Len: int

// Mouse_Cell is a terminal-space coordinate (cell units), not pixels.
Mouse_Cell :: struct {
	cx, cy: i32,
}

// Mouse_Cell_Pos is the cached mouse position in cell coords for the current frame.
Mouse_Cell_Pos: Mouse_Cell
// Mouse_Cell_Delta is the cached mouse movement in cell coords since the previous frame.
Mouse_Cell_Delta: Mouse_Cell
// Mouse_Sample_Initialized is false until we have taken at least one frame sample.
Mouse_Sample_Initialized: bool

// NOTE: Cell_W / Cell_H are host globals representing the pixel size of one terminal cell.
// They are computed by the font pipeline after fonts are loaded/rebuilt.


// -----------------------------------------------------------------------------
// Internal helpers (cell-space mouse conversion)
// -----------------------------------------------------------------------------

// sample_mouse_cell returns the current mouse position in terminal cell coordinates.
// Policy: floor(px / Cell_W) for hit-testing; negative window positions become -1.
sample_mouse_cell :: proc "contextless" () -> Mouse_Cell {
	// If cell metrics are not ready, return an obvious invalid cell.
	if Cell_W <= 0 || Cell_H <= 0 {
		return { -1, -1 }
	}

	pos := rl.GetMousePosition()

	// Guard negative floats before casting: cast(f32->i32) truncates toward 0.
	px: i32 = -1
	py: i32 = -1
	if pos.x >= 0 {
		px = cast(i32)(pos.x)
	}
	if pos.y >= 0 {
		py = cast(i32)(pos.y)
	}

	cx: i32 = -1
	cy: i32 = -1
	if px >= 0 {
		cx = px / Cell_W
	}
	if py >= 0 {
		cy = py / Cell_H
	}

	return { cx, cy }
}


// -----------------------------------------------------------------------------
// Host-driven per-frame refresh
// -----------------------------------------------------------------------------

// input_begin_frame refreshes per-frame input caches (typed text + mouse cell sample).
input_begin_frame :: proc() {
	// ---- text typed this frame ----
	Input_Text_Len = 0

	for {
		cp := rl.GetCharPressed()
		if cp == rune(0) {
			break
		}

		bytes, n := runtime.encode_rune(cp) // contextless
		if n <= 0 {
			continue
		}
		if Input_Text_Len + n > INPUT_TEXT_CAP {
			break // truncate
		}

		for i in 0..<n {
			Input_Text_Buf[Input_Text_Len+i] = bytes[i]
		}
		Input_Text_Len += n
	}

	// ---- mouse sample in cell space (once per frame) ----
	cur := sample_mouse_cell()

	if Mouse_Sample_Initialized {
		Mouse_Cell_Delta.cx = cur.cx - Mouse_Cell_Pos.cx
		Mouse_Cell_Delta.cy = cur.cy - Mouse_Cell_Pos.cy
	} else {
		Mouse_Cell_Delta.cx = 0
		Mouse_Cell_Delta.cy = 0
		Mouse_Sample_Initialized = true
	}

	Mouse_Cell_Pos = cur
}


// -----------------------------------------------------------------------------
// Registration
// -----------------------------------------------------------------------------

// register_input_api registers the tuicore.input Lua module table and its functions.
register_input_api :: proc(L: ^lua.State) {
	lua.newtable(L)

	// keyboard state/edges
	lua.pushcfunction(L, lua_input_key_down);     lua.setfield(L, -2, cstring("key_down"))
	lua.pushcfunction(L, lua_input_key_up);       lua.setfield(L, -2, cstring("key_up"))
	lua.pushcfunction(L, lua_input_key_pressed);  lua.setfield(L, -2, cstring("key_pressed"))
	lua.pushcfunction(L, lua_input_key_released); lua.setfield(L, -2, cstring("key_released"))
	lua.pushcfunction(L, lua_input_key_repeat);   lua.setfield(L, -2, cstring("key_repeat"))

	// text input
	lua.pushcfunction(L, lua_input_get_text);     lua.setfield(L, -2, cstring("get_text"))

	// mouse state/edges
	lua.pushcfunction(L, lua_input_mouse_down);     lua.setfield(L, -2, cstring("mouse_down"))
	lua.pushcfunction(L, lua_input_mouse_up);       lua.setfield(L, -2, cstring("mouse_up"))
	lua.pushcfunction(L, lua_input_mouse_pressed);  lua.setfield(L, -2, cstring("mouse_pressed"))
	lua.pushcfunction(L, lua_input_mouse_released); lua.setfield(L, -2, cstring("mouse_released"))

	// mouse pos + motion + wheel
	lua.pushcfunction(L, lua_input_mouse_pos);    lua.setfield(L, -2, cstring("mouse_pos"))
	lua.pushcfunction(L, lua_input_mouse_delta);  lua.setfield(L, -2, cstring("mouse_delta"))
	lua.pushcfunction(L, lua_input_mouse_wheel);  lua.setfield(L, -2, cstring("mouse_wheel"))

	push_lua_module(L, cstring("tuicore.input"))
}


// -----------------------------------------------------------------------------
// Token parsing + mapping (strings-only, fail-fast)
// -----------------------------------------------------------------------------

// check_lua_token reads a required Lua string argument and returns (string view, cstring ptr, byte length).
check_lua_token :: proc(L: ^lua.State, arg: c.int, who: cstring) -> (tok: string, p: cstring, n: int) {
	n_sz: c.size_t
	p = lua.L_checklstring(L, arg, &n_sz)
	n = int(n_sz)

	tok = strings.string_from_ptr(cast(^u8)p, n)

	if len(tok) == 0 {
		lua.L_error(L, cstring("%s: empty token"), who)
		return
	}

	return
}

// key_from_token maps a canonical key token to a raylib KeyboardKey (returns ok=false if unknown).
key_from_token :: proc "contextless" (tok: string) -> (rl.KeyboardKey, bool) {
	// Fast path: single-byte ASCII tokens for letters/digits/punctuation.
	if len(tok) == 1 {
		ch := tok[0]
		switch ch {
		// letters
		case 'a': return .A, true
		case 'b': return .B, true
		case 'c': return .C, true
		case 'd': return .D, true
		case 'e': return .E, true
		case 'f': return .F, true
		case 'g': return .G, true
		case 'h': return .H, true
		case 'i': return .I, true
		case 'j': return .J, true
		case 'k': return .K, true
		case 'l': return .L, true
		case 'm': return .M, true
		case 'n': return .N, true
		case 'o': return .O, true
		case 'p': return .P, true
		case 'q': return .Q, true
		case 'r': return .R, true
		case 's': return .S, true
		case 't': return .T, true
		case 'u': return .U, true
		case 'v': return .V, true
		case 'w': return .W, true
		case 'x': return .X, true
		case 'y': return .Y, true
		case 'z': return .Z, true

		// digits
		case '0': return .ZERO, true
		case '1': return .ONE, true
		case '2': return .TWO, true
		case '3': return .THREE, true
		case '4': return .FOUR, true
		case '5': return .FIVE, true
		case '6': return .SIX, true
		case '7': return .SEVEN, true
		case '8': return .EIGHT, true
		case '9': return .NINE, true

		// punctuation (literal tokens)
		case '\'': return .APOSTROPHE, true
		case ',':  return .COMMA, true
		case '-':  return .MINUS, true
		case '.':  return .PERIOD, true
		case '/':  return .SLASH, true
		case ';':  return .SEMICOLON, true
		case '=':  return .EQUAL, true
		case '[':  return .LEFT_BRACKET, true
		case '\\': return .BACKSLASH, true
		case ']':  return .RIGHT_BRACKET, true
		case '`':  return .GRAVE, true
		}
	}

	// Named keys (canonical, one spelling each).
	switch tok {
	case "space":     return .SPACE, true
	case "esc":       return .ESCAPE, true
	case "enter":     return .ENTER, true
	case "tab":       return .TAB, true
	case "backspace": return .BACKSPACE, true

	case "ins": return .INSERT, true
	case "del": return .DELETE, true

	case "right": return .RIGHT, true
	case "left":  return .LEFT, true
	case "down":  return .DOWN, true
	case "up":    return .UP, true

	case "pgup": return .PAGE_UP, true
	case "pgdn": return .PAGE_DOWN, true
	case "home": return .HOME, true
	case "end":  return .END, true

	case "capslock":   return .CAPS_LOCK, true
	case "scrolllock": return .SCROLL_LOCK, true
	case "numlock":    return .NUM_LOCK, true
	case "prtsc":      return .PRINT_SCREEN, true
	case "pause":      return .PAUSE, true

	// function keys
	case "f1":  return .F1, true
	case "f2":  return .F2, true
	case "f3":  return .F3, true
	case "f4":  return .F4, true
	case "f5":  return .F5, true
	case "f6":  return .F6, true
	case "f7":  return .F7, true
	case "f8":  return .F8, true
	case "f9":  return .F9, true
	case "f10": return .F10, true
	case "f11": return .F11, true
	case "f12": return .F12, true

	// modifiers (explicit left/right, no aliases)
	case "lshift": return .LEFT_SHIFT, true
	case "lctrl":  return .LEFT_CONTROL, true
	case "lalt":   return .LEFT_ALT, true
	case "lsuper": return .LEFT_SUPER, true

	case "rshift": return .RIGHT_SHIFT, true
	case "rctrl":  return .RIGHT_CONTROL, true
	case "ralt":   return .RIGHT_ALT, true
	case "rsuper": return .RIGHT_SUPER, true

	case "menu": return .KB_MENU, true

	// numpad (canonical)
	case "numpad0": return .KP_0, true
	case "numpad1": return .KP_1, true
	case "numpad2": return .KP_2, true
	case "numpad3": return .KP_3, true
	case "numpad4": return .KP_4, true
	case "numpad5": return .KP_5, true
	case "numpad6": return .KP_6, true
	case "numpad7": return .KP_7, true
	case "numpad8": return .KP_8, true
	case "numpad9": return .KP_9, true

	case "numpad.":     return .KP_DECIMAL, true
	case "numpad/":     return .KP_DIVIDE, true
	case "numpad*":     return .KP_MULTIPLY, true
	case "numpad-":     return .KP_SUBTRACT, true
	case "numpad+":     return .KP_ADD, true
	case "numpadenter": return .KP_ENTER, true
	case "numpad=":     return .KP_EQUAL, true
	}

	return .KEY_NULL, false
}

// mouse_from_token maps a canonical mouse button token to a raylib MouseButton (returns ok=false if unknown).
mouse_from_token :: proc "contextless" (tok: string) -> (rl.MouseButton, bool) {
	switch tok {
	case "left":   return .LEFT, true
	case "right":  return .RIGHT, true
	case "middle": return .MIDDLE, true
	}
	return .LEFT, false
}


// -----------------------------------------------------------------------------
// Lua API (keyboard)
// -----------------------------------------------------------------------------

// input.key_down(tok) -> bool: true while the key is held down.
lua_input_key_down :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	tok, p, n := check_lua_token(L, 1, cstring("input.key_down"))
	key, ok := key_from_token(tok)
	if !ok {
		return lua.L_error(L, cstring("input.key_down: unknown key '%.*s'"), n, p)
	}
	lua.pushboolean(L, b32(rl.IsKeyDown(key)))
	return 1
}

// input.key_up(tok) -> bool: true while the key is not held down.
lua_input_key_up :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	tok, p, n := check_lua_token(L, 1, cstring("input.key_up"))
	key, ok := key_from_token(tok)
	if !ok {
		return lua.L_error(L, cstring("input.key_up: unknown key '%.*s'"), n, p)
	}
	lua.pushboolean(L, b32(rl.IsKeyUp(key)))
	return 1
}

// input.key_pressed(tok) -> bool: true on the frame the key transitions up->down.
lua_input_key_pressed :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	tok, p, n := check_lua_token(L, 1, cstring("input.key_pressed"))
	key, ok := key_from_token(tok)
	if !ok {
		return lua.L_error(L, cstring("input.key_pressed: unknown key '%.*s'"), n, p)
	}
	lua.pushboolean(L, b32(rl.IsKeyPressed(key)))
	return 1
}

// input.key_released(tok) -> bool: true on the frame the key transitions down->up.
lua_input_key_released :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	tok, p, n := check_lua_token(L, 1, cstring("input.key_released"))
	key, ok := key_from_token(tok)
	if !ok {
		return lua.L_error(L, cstring("input.key_released: unknown key '%.*s'"), n, p)
	}
	lua.pushboolean(L, b32(rl.IsKeyReleased(key)))
	return 1
}

// input.key_repeat(tok) -> bool: true on key repeat events while the key is held.
lua_input_key_repeat :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	tok, p, n := check_lua_token(L, 1, cstring("input.key_repeat"))
	key, ok := key_from_token(tok)
	if !ok {
		return lua.L_error(L, cstring("input.key_repeat: unknown key '%.*s'"), n, p)
	}
	lua.pushboolean(L, b32(rl.IsKeyPressedRepeat(key)))
	return 1
}


// -----------------------------------------------------------------------------
// Lua API (text)
// -----------------------------------------------------------------------------

// input.get_text() -> string: UTF-8 text typed this frame (may be empty).
lua_input_get_text :: proc "c" (L: ^lua.State) -> c.int {
	if Input_Text_Len <= 0 {
		lua.pushlstring(L, cstring(""), 0)
		return 1
	}

	p := cast(cstring)(&Input_Text_Buf[0])
	lua.pushlstring(L, p, c.size_t(Input_Text_Len))
	return 1
}


// -----------------------------------------------------------------------------
// Lua API (mouse buttons)
// -----------------------------------------------------------------------------

// input.mouse_down(btn) -> bool: true while the mouse button is held.
lua_input_mouse_down :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	tok, p, n := check_lua_token(L, 1, cstring("input.mouse_down"))
	btn, ok := mouse_from_token(tok)
	if !ok {
		return lua.L_error(L, cstring("input.mouse_down: unknown button '%.*s'"), n, p)
	}
	lua.pushboolean(L, b32(rl.IsMouseButtonDown(btn)))
	return 1
}

// input.mouse_up(btn) -> bool: true while the mouse button is not held.
lua_input_mouse_up :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	tok, p, n := check_lua_token(L, 1, cstring("input.mouse_up"))
	btn, ok := mouse_from_token(tok)
	if !ok {
		return lua.L_error(L, cstring("input.mouse_up: unknown button '%.*s'"), n, p)
	}
	lua.pushboolean(L, b32(rl.IsMouseButtonUp(btn)))
	return 1
}

// input.mouse_pressed(btn) -> bool: true on the frame the button transitions up->down.
lua_input_mouse_pressed :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	tok, p, n := check_lua_token(L, 1, cstring("input.mouse_pressed"))
	btn, ok := mouse_from_token(tok)
	if !ok {
		return lua.L_error(L, cstring("input.mouse_pressed: unknown button '%.*s'"), n, p)
	}
	lua.pushboolean(L, b32(rl.IsMouseButtonPressed(btn)))
	return 1
}

// input.mouse_released(btn) -> bool: true on the frame the button transitions down->up.
lua_input_mouse_released :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	tok, p, n := check_lua_token(L, 1, cstring("input.mouse_released"))
	btn, ok := mouse_from_token(tok)
	if !ok {
		return lua.L_error(L, cstring("input.mouse_released: unknown button '%.*s'"), n, p)
	}
	lua.pushboolean(L, b32(rl.IsMouseButtonReleased(btn)))
	return 1
}


// -----------------------------------------------------------------------------
// Lua API (mouse motion in cell space)
// -----------------------------------------------------------------------------

// input.mouse_pos() -> cx, cy: current mouse position in terminal cell coordinates.
lua_input_mouse_pos :: proc "c" (L: ^lua.State) -> c.int {
	if Mouse_Sample_Initialized {
		lua.pushinteger(L, cast(lua.Integer)(Mouse_Cell_Pos.cx))
		lua.pushinteger(L, cast(lua.Integer)(Mouse_Cell_Pos.cy))
		return 2
	}

	// If called before the first frame sample, return a live sample (still cell space).
	cur := sample_mouse_cell()
	lua.pushinteger(L, cast(lua.Integer)(cur.cx))
	lua.pushinteger(L, cast(lua.Integer)(cur.cy))
	return 2
}

// input.mouse_delta() -> dcx, dcy: mouse movement in terminal cell coordinates since the previous frame.
lua_input_mouse_delta :: proc "c" (L: ^lua.State) -> c.int {
	if !Mouse_Sample_Initialized {
		lua.pushinteger(L, 0)
		lua.pushinteger(L, 0)
		return 2
	}

	lua.pushinteger(L, cast(lua.Integer)(Mouse_Cell_Delta.cx))
	lua.pushinteger(L, cast(lua.Integer)(Mouse_Cell_Delta.cy))
	return 2
}

// input.mouse_wheel() -> dx, dy: wheel units from raylib (not pixels; typically fractional).
lua_input_mouse_wheel :: proc "c" (L: ^lua.State) -> c.int {
	w := rl.GetMouseWheelMoveV()
	lua.pushnumber(L, lua.Number(w.x))
	lua.pushnumber(L, lua.Number(w.y))
	return 2
}

