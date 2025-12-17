package main

// lua_input.odin
//
// input.* Lua API (keyboard + mouse), backed by raylib.
//
// Lua surface (strings-only tokens):
// - Keyboard: key_down, key_up, key_pressed, key_released, key_repeat
// - Text:     get_text() -> string (all UTF-8 typed this frame)
// - Mouse:    mouse_down, mouse_up, mouse_pressed, mouse_released
// - Mouse:    mouse_pos() -> x, y
// - Mouse:    mouse_delta() -> dx, dy
// - Mouse:    mouse_wheel() -> dx, dy
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
// - Call input_begin_frame() once per frame (before Lua update) to refresh text cache.

import rl      "vendor:raylib"
import lua     "luajit"
import strings "core:strings"
import runtime "base:runtime"
import c       "core:c"


// -----------------------------------------------------------------------------
// Host-driven per-frame text cache
// -----------------------------------------------------------------------------

INPUT_TEXT_CAP :: 4096

Input_Text_Buf: [INPUT_TEXT_CAP]u8
Input_Text_Len: int

// input_begin_frame refreshes text typed this frame.
// Call once per frame, before Lua update().
input_begin_frame :: proc() {
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
			break // truncate (cap is huge for “typed this frame”)
		}

		for i in 0..<n {
			Input_Text_Buf[Input_Text_Len+i] = bytes[i]
		}
		Input_Text_Len += n
	}
}


// -----------------------------------------------------------------------------
// Registration
// -----------------------------------------------------------------------------

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

mouse_from_token :: proc "contextless" (tok: string) -> (rl.MouseButton, bool) {
	// Keep this tiny and canonical.
	switch tok {
	case "left":   return .LEFT, true
	case "right":  return .RIGHT, true
	case "middle": return .MIDDLE, true
	}
	return .LEFT, false
}


// -----------------------------------------------------------------------------
// Lua API
// -----------------------------------------------------------------------------

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

// input.get_text() -> string (UTF-8 typed this frame, possibly empty)
lua_input_get_text :: proc "c" (L: ^lua.State) -> c.int {
	if Input_Text_Len <= 0 {
		lua.pushlstring(L, cstring(""), 0)
		return 1
	}

	p := cast(cstring)(&Input_Text_Buf[0])
	lua.pushlstring(L, p, c.size_t(Input_Text_Len))
	return 1
}

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

// input.mouse_pos() -> x, y (integers)
lua_input_mouse_pos :: proc "c" (L: ^lua.State) -> c.int {
	pos := rl.GetMousePosition()
	lua.pushinteger(L, lua.Integer(int(pos.x)))
	lua.pushinteger(L, lua.Integer(int(pos.y)))
	return 2
}

// input.mouse_delta() -> dx, dy (numbers)
lua_input_mouse_delta :: proc "c" (L: ^lua.State) -> c.int {
	d := rl.GetMouseDelta()
	lua.pushnumber(L, lua.Number(d.x))
	lua.pushnumber(L, lua.Number(d.y))
	return 2
}

// input.mouse_wheel() -> dx, dy (numbers)
lua_input_mouse_wheel :: proc "c" (L: ^lua.State) -> c.int {
	w := rl.GetMouseWheelMoveV()
	lua.pushnumber(L, lua.Number(w.x))
	lua.pushnumber(L, lua.Number(w.y))
	return 2
}

