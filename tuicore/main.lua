local window = require("tuicore.window")
local draw   = require("tuicore.draw")
local input  = require("tuicore.input")

-- colors {r,g,b,a}
local C_BG     = { 16, 18, 24, 255 }
local C_PANEL  = { 24, 28, 36, 255 }
local C_LINE   = { 40, 46, 60, 255 }
local C_TEXT   = { 220, 220, 220, 255 }
local C_MUTED  = { 160, 170, 190, 255 }
local C_ACCENT = { 120, 200, 255, 255 }
local C_WARN   = { 255, 180, 100, 255 }

-- indicator colors
local C_ON   = {  70, 220, 120, 255 } -- green
local C_OFF  = { 220,  70,  70, 255 } -- red

local state = {
  t = 0,
  typed = "",
  last_frame_text = "",
  px = 5,
  py = 6,
  last_click = "",
  wheel_x = 0,
  wheel_y = 0,
}

-- remove last UTF-8 codepoint (works fine for ASCII + UTF-8)
local function utf8_pop(s)
  local n = #s
  if n == 0 then return s end
  local i = n
  while i > 0 do
    local c = string.byte(s, i)
    if c < 128 or c >= 192 then
      return string.sub(s, 1, i - 1)
    end
    i = i - 1
  end
  return ""
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function cell_bool(x, y, v)
  draw.cell(x, y, v and C_ON or C_OFF)
end

-- Draw key states as colored cells: Down / Pressed / Released / Repeat
local function row_key_states(x, y, label, key)
  draw.text(x, y, label, C_MUTED)

  local bx = x + 10
  draw.text(bx,    y, "D", C_MUTED) ; cell_bool(bx+2,  y, input.key_down(key))
  draw.text(bx+4,  y, "P", C_MUTED) ; cell_bool(bx+6,  y, input.key_pressed(key))
  draw.text(bx+8,  y, "R", C_MUTED) ; cell_bool(bx+10, y, input.key_released(key))
  draw.text(bx+12, y, "T", C_MUTED) ; cell_bool(bx+14, y, input.key_repeat(key))
end

-- Draw mouse states as colored cells: Down / Pressed / Released
local function row_mouse_states(x, y, label, btn)
  draw.text(x, y, label, C_MUTED)

  local bx = x + 10
  draw.text(bx,   y, "D", C_MUTED) ; cell_bool(bx+2,  y, input.mouse_down(btn))
  draw.text(bx+4, y, "P", C_MUTED) ; cell_bool(bx+6,  y, input.mouse_pressed(btn))
  draw.text(bx+8, y, "R", C_MUTED) ; cell_bool(bx+10, y, input.mouse_released(btn))
end

function init_terminal()
  window.init(960, 540, "tuicore input test", { "vsync_on", "resizable" })
  window.set_fps_limit(60)
end

function update_terminal(dt)
  state.t = state.t + dt

  -- typed text this frame (host must call input_begin_frame() before this)
  local s = input.get_text()
  state.last_frame_text = s
  if s ~= "" then
    state.typed = state.typed .. s
    if #state.typed > 512 then
      state.typed = string.sub(state.typed, #state.typed - 512 + 1)
    end
  end

  -- editing demo: backspace uses pressed OR repeat
  if input.key_pressed("backspace") or input.key_repeat("backspace") then
    state.typed = utf8_pop(state.typed)
  end

  -- move @ with WASD (hold)
  if input.key_down("w") then state.py = state.py - 1 end
  if input.key_down("s") then state.py = state.py + 1 end
  if input.key_down("a") then state.px = state.px - 1 end
  if input.key_down("d") then state.px = state.px + 1 end

  -- keep inside terminal bounds (leave room for right panel)
  local panel_w = 30
  state.px = clamp(state.px, 0, TERM_COLS - panel_w - 1)
  state.py = clamp(state.py, 0, TERM_ROWS - 1)

  -- mouse -> teleport @ on left click (convert pixels -> cell approx)
  local mx, my = input.mouse_pos()
  local ww, wh = window.get_size()
  local cell_w = ww / TERM_COLS
  local cell_h = wh / TERM_ROWS
  local cx = math.floor(mx / cell_w)
  local cy = math.floor(my / cell_h)

  if input.mouse_pressed("left") then
    state.px = clamp(cx, 0, TERM_COLS - panel_w - 1)
    state.py = clamp(cy, 0, TERM_ROWS - 1)
    state.last_click = string.format("left @ px(%d,%d) -> cell(%d,%d)", mx, my, state.px, state.py)
  end

  -- wheel (accumulate so you can see it)
  local wx, wy = input.mouse_wheel()
  if wx ~= 0 or wy ~= 0 then
    state.wheel_x = state.wheel_x + wx
    state.wheel_y = state.wheel_y + wy
  end
end

function draw_terminal()
  draw.clear(C_BG)

  local panel_w = 30
  local panel_x = TERM_COLS - panel_w

  -- right panel background + divider
  draw.rect(panel_x, 0, panel_w, TERM_ROWS, C_PANEL)
  draw.rect(panel_x, 0, 1, TERM_ROWS, C_LINE)

  -- title
  draw.text(1, 0, "tuicore draw+input smoke test", C_TEXT)
  draw.text(1, 1, "type text, hold WASD, backspace edits, left-click teleports @", C_MUTED)

  -- draw a moving @
  draw.glyph(state.px, state.py, C_ACCENT, "@", 0)

  -- panel content
  local x = panel_x + 1
  local y = 0

  draw.text(x, y, "INPUT", C_TEXT) ; y = y + 2

  draw.text(x, y, "keys", C_TEXT) ; y = y + 1
  draw.text(x, y, "      D  P  R  T", C_MUTED) ; y = y + 1

  row_key_states(x, y, "w", "w") ; y = y + 1
  row_key_states(x, y, "a", "a") ; y = y + 1
  row_key_states(x, y, "s", "s") ; y = y + 1
  row_key_states(x, y, "d", "d") ; y = y + 1
  y = y + 1

  row_key_states(x, y, "space", "space") ; y = y + 1
  row_key_states(x, y, "enter", "enter") ; y = y + 1
  row_key_states(x, y, "tab", "tab") ; y = y + 1
  row_key_states(x, y, "backspace", "backspace") ; y = y + 2

  local mx, my = input.mouse_pos()
  local dx, dy = input.mouse_delta()
  local wx, wy = input.mouse_wheel()

  draw.text(x, y, "mouse", C_TEXT) ; y = y + 1
  draw.text(x, y, string.format("pos: %d,%d", mx, my), C_TEXT) ; y = y + 1
  draw.text(x, y, string.format("delta: %.2f,%.2f", dx, dy), C_TEXT) ; y = y + 1
  draw.text(x, y, string.format("wheel: %.2f,%.2f", wx, wy), C_TEXT) ; y = y + 2

  draw.text(x, y, "mouse buttons", C_TEXT) ; y = y + 1
  draw.text(x, y, "      D  P  R", C_MUTED) ; y = y + 1
  row_mouse_states(x, y, "left", "left") ; y = y + 1
  row_mouse_states(x, y, "right", "right") ; y = y + 1
  row_mouse_states(x, y, "middle", "middle") ; y = y + 2

  draw.text(x, y, "text", C_TEXT) ; y = y + 1
  draw.text(x, y, "frame:", C_MUTED) ; y = y + 1
  draw.text(x, y, state.last_frame_text ~= "" and state.last_frame_text or "<empty>", C_TEXT, panel_w - 2) ; y = y + 1
  draw.text(x, y, "buffer:", C_MUTED) ; y = y + 1
  draw.text(x, y, state.typed ~= "" and state.typed or "<empty>", C_WARN, panel_w - 2) ; y = y + 2

  if state.last_click ~= "" then
    draw.text(x, y, "last click:", C_MUTED) ; y = y + 1
    draw.text(x, y, state.last_click, C_TEXT, panel_w - 2) ; y = y + 1
  end

  -- tiny footer showing accumulated wheel (handy sanity check)
  draw.text(1, TERM_ROWS - 1, string.format("wheel sum: %.2f, %.2f", state.wheel_x, state.wheel_y), C_MUTED)
end

