local window = require("tuicore.window")
local draw   = require("tuicore.draw")
local input  = require("tuicore.input")
local font   = require("tuicore.font")

-- colors {r,g,b,a}
local C_BG        = { 16, 18, 24, 255 }
local C_PANEL     = { 24, 28, 36, 255 }
local C_PANEL_2   = { 20, 24, 31, 255 }
local C_LINE      = { 40, 46, 60, 255 }
local C_TEXT      = { 220, 220, 220, 255 }
local C_MUTED     = { 160, 170, 190, 255 }
local C_ACCENT    = { 120, 200, 255, 255 }
local C_WARN      = { 255, 180, 100, 255 }

-- indicator colors
local C_ON        = {  70, 220, 120, 255 } -- green (state held)
local C_EDGE      = { 255, 180, 100, 255 } -- orange (edge pulses)
local C_OFF       = { 120, 130, 150, 255 } -- muted

-- UI tuning
local EDGE_HOLD_S   = 0.22   -- pressed/released stay visible this long
local REPEAT_HOLD_S = 0.08   -- repeat blinks: short hold so it doesn't look stuck
local MAX_BUFFER    = 2048

local state = {
  t = 0,

  -- typed text
  typed = "",
  last_input = "<none>",
  last_input_age = 999,

  -- demo entity (cell-space)
  px = 0,
  py = 0,

  -- wheel (accumulate)
  wheel_x = 0,
  wheel_y = 0,

  -- edge pulses (timers)
  key_p = {}, key_r = {}, key_rep = {},
  mouse_p = {}, mouse_r = {},

  -- repeat blink phase (toggles on each repeat event)
  key_rep_flip = {},

  -- clipboard test
  clipboard = "",
  clipboard_age = 999,
  clipboard_poll_t = 0,
  clipboard_msg = "",

  -- cursor test
  cursor_tok = "arrow",
  cursor_hidden = false,

  -- ui cache (computed each update)
  ui = nil,
}

-- init_terminal sets up a resizable window with vsync.
function init_terminal()
  window.init(960, 540, "tuicore input test", { "vsync_on", "resizable" })
  window.set_fps_limit(60)

  -- cursor needs to be visible to test SetMouseCursor
  state.cursor_hidden = false
  window.set_cursor_hidden(false)

  font.init(14,{
    "C:/Users/theja/AppData/Local/Microsoft/Windows/Fonts/IosevkaQuillwyrm-Regular.ttf",
    "C:/Users/theja/AppData/Local/Microsoft/Windows/Fonts/IosevkaQuillwyrm-Bold.ttf",
    "C:/Users/theja/AppData/Local/Microsoft/Windows/Fonts/IosevkaQuillwyrm-Italic.ttf",
    "C:/Users/theja/AppData/Local/Microsoft/Windows/Fonts/IosevkaQuillwyrm-BoldItalic.ttf"
  })

  -- seed clipboard display (best effort)
  state.clipboard = window.get_clipboard() or ""
  state.clipboard_age = 0
end

-- utf8_pop removes the last UTF-8 codepoint (good enough for typed-buffer editing).
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

-- clamp clamps v into [lo, hi].
local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- tick_pulses decrements all pulse timers in a table by dt, removing expired entries.
local function tick_pulses(dt, t)
  for k, v in pairs(t) do
    v = v - dt
    if v <= 0 then
      t[k] = nil
    else
      t[k] = v
    end
  end
end

-- pulse sets a named timer to duration (seconds).
local function pulse(t, name, duration)
  t[name] = duration
end

-- box draws a filled rect with a 1-cell border.
local function box(x, y, w, h, fill, border)
  if w <= 0 or h <= 0 then return end
  draw.rect(x, y, w, h, fill)
  draw.rect(x, y, w, 1, border)
  draw.rect(x, y + h - 1, w, 1, border)
  draw.rect(x, y, 1, h, border)
  draw.rect(x + w - 1, y, 1, h, border)
end

local function in_rect(px, py, x, y, w, h)
  return (px >= x and px < x + w and py >= y and py < y + h)
end

-- utf8_iter returns an iterator over UTF-8 "characters" (substrings).
local function utf8_iter(s)
  local i, n = 1, #s
  return function()
    if i > n then return nil end
    local c = string.byte(s, i)
    local len = 1
    if c >= 0xF0 then len = 4
    elseif c >= 0xE0 then len = 3
    elseif c >= 0xC0 then len = 2
    end
    local ch = string.sub(s, i, i + len - 1)
    i = i + len
    return ch
  end
end

-- wrap_lines wraps UTF-8 text into lines of at most max_w cells (simple cell-wrap).
local function wrap_lines(s, max_w)
  if max_w <= 0 then return { "" } end
  if s == "" then return { "" } end

  local lines = {}
  local line = {}
  local line_len = 0
  local last_space_at = nil

  local function flush_line()
    table.insert(lines, table.concat(line))
    line = {}
    line_len = 0
    last_space_at = nil
  end

  for ch in utf8_iter(s) do
    if ch == "\n" then
      flush_line()
    else
      table.insert(line, ch)
      line_len = line_len + 1
      if ch == " " or ch == "\t" then
        last_space_at = #line
      end

      if line_len > max_w then
        if last_space_at and last_space_at >= 1 then
          local head = {}
          for i = 1, last_space_at - 1 do head[i] = line[i] end
          table.insert(lines, table.concat(head))

          local tail = {}
          for i = last_space_at + 1, #line do
            table.insert(tail, line[i])
          end
          line = tail
          line_len = #line
          last_space_at = nil
          for i = 1, #line do
            local c = line[i]
            if c == " " or c == "\t" then last_space_at = i end
          end
        else
          local head = {}
          for i = 1, max_w do head[i] = line[i] end
          table.insert(lines, table.concat(head))

          local tail = {}
          for i = max_w + 1, #line do
            table.insert(tail, line[i])
          end
          line = tail
          line_len = #line
          last_space_at = nil
          for i = 1, #line do
            local c = line[i]
            if c == " " or c == "\t" then last_space_at = i end
          end
        end
      end
    end
  end

  flush_line()
  return lines
end

-- draw_boxed_text draws wrapped text inside a box, showing the last lines that fit.
local function draw_boxed_text(x, y, w, h, title, text, title_col, text_col)
  box(x, y, w, h, C_PANEL_2, C_LINE)

  local pad_x = 1
  local tx = x + pad_x
  local tw = w - pad_x * 2

  -- title
  draw.text(tx, y, title, title_col)

  -- content area is rows [y+1 .. y+h-2]
  local ty = y + 1
  local th = h - 2
  if tw <= 0 or th <= 0 then return end

  local lines = wrap_lines(text, tw)
  local start = #lines - th + 1
  if start < 1 then start = 1 end

  local row = 0
  for i = start, #lines do
    if row >= th then break end
    draw.text(tx, ty + row, lines[i], text_col)
    row = row + 1
  end
end

-- mark draws an on/off symbol in one cell (used for edge pulses).
local function mark(x, y, on, sym_on, sym_off, col_on, col_off)
  if on then
    draw.glyph(x, y, col_on, sym_on, 0)
  else
    draw.glyph(x, y, col_off, sym_off, 0)
  end
end

-- state_mark draws a "held state" indicator (Down) as a colored cell.
local function state_mark(x, y, on)
  draw.cell(x, y, on and C_ON or C_OFF)
end

-- row_key_states renders key state + edge pulses (Pressed/Released/Repeat).
local function row_key_states(x, y, label, key)
  draw.text(x, y, label, C_MUTED)

  local bx = x + 14

  -- held state
  draw.text(bx, y, "D", C_MUTED)
  state_mark(bx + 2, y, input.key_down(key))

  -- edges (symbols)
  draw.text(bx + 5, y, "P", C_MUTED)
  mark(bx + 7, y, (state.key_p[key] ~= nil), "●", "·", C_EDGE, C_OFF)

  draw.text(bx + 9, y, "R", C_MUTED)
  mark(bx + 11, y, (state.key_r[key] ~= nil), "●", "·", C_EDGE, C_OFF)

  -- repeat: blink by flipping symbol each repeat event
  draw.text(bx + 13, y, "Rep", C_MUTED)
  local rep_on = (state.key_rep[key] ~= nil)
  local flip = state.key_rep_flip[key] and true or false
  if rep_on then
    mark(bx + 17, y, true, flip and "●" or "○", "·", C_WARN, C_OFF)
  else
    mark(bx + 17, y, false, "●", "·", C_WARN, C_OFF)
  end
end

-- row_mouse_states renders mouse button state + edge pulses (Pressed/Released).
local function row_mouse_states(x, y, label, btn)
  draw.text(x, y, label, C_MUTED)

  local bx = x + 14

  draw.text(bx, y, "D", C_MUTED)
  state_mark(bx + 2, y, input.mouse_down(btn))

  draw.text(bx + 5, y, "P", C_MUTED)
  mark(bx + 7, y, (state.mouse_p[btn] ~= nil), "●", "·", C_EDGE, C_OFF)

  draw.text(bx + 9, y, "R", C_MUTED)
  mark(bx + 11, y, (state.mouse_r[btn] ~= nil), "●", "·", C_EDGE, C_OFF)
end

-- layout: make INFO wide, WORLD narrow.
-- returns panel_w, world_x0, world_x1
local function layout(cols)
  local min_world = 18
  local panel_w = math.floor(cols * 0.72)
  if panel_w > cols - min_world - 2 then panel_w = cols - min_world - 2 end
  if panel_w < 0 then panel_w = 0 end
  local world_x0 = panel_w + 2
  local world_x1 = cols - 1
  return panel_w, world_x0, world_x1
end

local function clamp_buffer(s)
  if #s > MAX_BUFFER then
    return string.sub(s, #s - MAX_BUFFER + 1)
  end
  return s
end

local function set_cursor(tok)
  if state.cursor_hidden then return end
  if tok == state.cursor_tok then return end
  state.cursor_tok = tok
  window.set_mouse_cursor(tok)
end

-- compute UI rectangles once per update so clicks/cursor logic is deterministic.
local function compute_ui(cols, rows)
  local panel_w, world_x0, world_x1 = layout(cols)
  local world_w = cols - world_x0

  local x = 2
  local y = 1

  -- INFO block (same as draw)
  y = y + 1
  y = y + 1
  y = y + 2 -- after world line

  local box_x = x
  local box_w = panel_w - 4
  if box_w < 0 then box_w = 0 end

  -- CLIPBOARD block
  local clip_header_y = y
  local btn_h = 3
  local btn_gap = 1

  local buttons = {}
  local function add_button(id, label)
    local w = #label + 4
    return { id = id, label = label, w = w, h = btn_h, x = 0, y = 0 }
  end

  local btn_list = {
    add_button("copy",   "copy typed"),
    add_button("paste",  "paste+"),
    add_button("replace","replace"),
    add_button("demo",   "demo"),
    add_button("clear",  "clear"),
    add_button("cursor", "toggle cursor"),
    add_button("poll",   "poll now"),
  }

  local bx = box_x
  local by = clip_header_y + 1

  for i = 1, #btn_list do
    local b = btn_list[i]
    if box_w > 0 and bx + b.w > box_x + box_w then
      bx = box_x
      by = by + btn_h + btn_gap
    end
    b.x, b.y = bx, by
    buttons[#buttons+1] = b
    bx = bx + b.w + btn_gap
  end

  local btn_block_bottom = by + btn_h
  local clip_box_y = btn_block_bottom + 1
  local clip_h = 6

  local clip_box = { x = box_x, y = clip_box_y, w = box_w, h = clip_h }

  local after_clip_y = clip_box_y + clip_h + 1

  -- INPUT section starts after clipboard area
  local input_y0 = after_clip_y

  -- later: boxed text areas use remaining space
  local last_h = 5
  local buf_h  = math.max(7, rows - (input_y0 + 2) - 3)

  -- we match draw’s later placement:
  -- input uses a variable amount; we can’t precompute typed box without redoing all those y increments
  -- so we compute it in draw and also for cursor we treat "typed buffer box" via the same math in draw.

  return {
    panel_w = panel_w,
    world_x0 = world_x0,
    world_x1 = world_x1,
    world_w = world_w,

    box_x = box_x,
    box_w = box_w,

    clip_header_y = clip_header_y,
    buttons = buttons,
    clip_box = clip_box,
    input_y0 = input_y0,

    last_h = last_h,
    buf_h = buf_h,
  }
end

local function find_button(ui, mx, my)
  for i = 1, #ui.buttons do
    local b = ui.buttons[i]
    if in_rect(mx, my, b.x, b.y, b.w, b.h) then
      return b
    end
  end
  return nil
end

local function clipboard_set(s, msg)
  window.set_clipboard(s)
  state.clipboard = s
  state.clipboard_age = 0
  state.clipboard_poll_t = 0
  state.clipboard_msg = msg or ""
end

-- update_terminal advances the demo + captures input state for rendering.
function update_terminal(dt)
  local cols, rows = window.grid_size()
  if cols <= 0 or rows <= 0 then return end

  state.ui = compute_ui(cols, rows)

  state.t = state.t + dt

  -- fade pulse timers
  tick_pulses(dt, state.key_p)
  tick_pulses(dt, state.key_r)
  tick_pulses(dt, state.key_rep)
  tick_pulses(dt, state.mouse_p)
  tick_pulses(dt, state.mouse_r)

  -- clipboard polling (so you can alt-tab and copy elsewhere)
  state.clipboard_poll_t = state.clipboard_poll_t + dt
  state.clipboard_age = state.clipboard_age + dt
  if state.clipboard_poll_t >= 0.25 then
    state.clipboard_poll_t = 0
    local s = window.get_clipboard() or ""
    if s ~= state.clipboard then
      state.clipboard = s
      state.clipboard_age = 0
      state.clipboard_msg = "clipboard changed externally"
    end
  end

  -- typed text this frame (host must call input_begin_frame() before this)
  local s = input.get_text()
  if s ~= "" then
    state.last_input = s
    state.last_input_age = 0

    state.typed = clamp_buffer(state.typed .. s)
  else
    state.last_input_age = state.last_input_age + dt
  end

  -- keys we display (and pulse)
  local keys = { "w", "a", "s", "d", "space", "enter", "tab", "backspace" }
  for i = 1, #keys do
    local k = keys[i]
    if input.key_pressed(k) then pulse(state.key_p, k, EDGE_HOLD_S) end
    if input.key_released(k) then pulse(state.key_r, k, EDGE_HOLD_S) end
    if input.key_repeat(k) then
      pulse(state.key_rep, k, REPEAT_HOLD_S)
      state.key_rep_flip[k] = not state.key_rep_flip[k]
    end
  end

  -- editing demo: backspace uses pressed OR repeat
  if input.key_pressed("backspace") or input.key_repeat("backspace") then
    state.typed = utf8_pop(state.typed)
  end

  local panel_w, world_x0, world_x1 = state.ui.panel_w, state.ui.world_x0, state.ui.world_x1

  -- initial placement (only once)
  if state.px == 0 and state.py == 0 then
    state.px = world_x0 + 2
    state.py = 6
  end

  -- move @ with WASD (hold)
  if input.key_down("w") then state.py = state.py - 1 end
  if input.key_down("s") then state.py = state.py + 1 end
  if input.key_down("a") then state.px = state.px - 1 end
  if input.key_down("d") then state.px = state.px + 1 end

  -- keep inside world bounds
  state.px = clamp(state.px, world_x0, world_x1)
  state.py = clamp(state.py, 0, rows - 1)

  -- mouse cell-space (tuicore.input is cell-native)
  local mx, my = input.mouse_pos()

  -- mouse button pulses
  local btns = { "left", "right", "middle" }
  for i = 1, #btns do
    local b = btns[i]
    if input.mouse_pressed(b) then pulse(state.mouse_p, b, EDGE_HOLD_S) end
    if input.mouse_released(b) then pulse(state.mouse_r, b, EDGE_HOLD_S) end
  end

  -- teleport @ on left click (cell-space) if you click in world (not panel)
  if input.mouse_pressed("left") and mx >= world_x0 then
    state.px = clamp(mx, world_x0, world_x1)
    state.py = clamp(my, 0, rows - 1)
  end

  -- wheel (accumulate so you can see it)
  local wx, wy = input.mouse_wheel()
  if wx ~= 0 or wy ~= 0 then
    state.wheel_x = state.wheel_x + wx
    state.wheel_y = state.wheel_y + wy
  end

  -- ---------------------------------------------------------------------------
  -- Clipboard button actions + cursor testing
  -- ---------------------------------------------------------------------------
  local ui = state.ui
  local hovered_btn = find_button(ui, mx, my)

  -- divider cursor test
  if mx == ui.panel_w then
    set_cursor("resize_ew")
  elseif hovered_btn then
    set_cursor("pointing_hand")
  elseif ui.clip_box.w > 0 and in_rect(mx, my, ui.clip_box.x, ui.clip_box.y, ui.clip_box.w, ui.clip_box.h) then
    set_cursor("ibeam")
  elseif mx >= ui.world_x0 then
    set_cursor("crosshair")
  else
    set_cursor("arrow")
  end

  if input.mouse_pressed("left") and hovered_btn then
    if hovered_btn.id == "copy" then
      clipboard_set(state.typed, "copied typed -> clipboard")
    elseif hovered_btn.id == "paste" then
      state.typed = clamp_buffer(state.typed .. (state.clipboard or ""))
      state.clipboard_msg = "pasted clipboard -> typed (append)"
    elseif hovered_btn.id == "replace" then
      state.typed = clamp_buffer(state.clipboard or "")
      state.clipboard_msg = "pasted clipboard -> typed (replace)"
    elseif hovered_btn.id == "demo" then
      clipboard_set("tuicore clipboard test\nline 2\nunicode: Ω≈ç√∫˜µ≤≥÷  🙂", "set demo clipboard text")
    elseif hovered_btn.id == "clear" then
      clipboard_set("", "cleared clipboard")
    elseif hovered_btn.id == "cursor" then
      state.cursor_hidden = not state.cursor_hidden
      window.set_cursor_hidden(state.cursor_hidden)
      state.clipboard_msg = state.cursor_hidden and "cursor hidden (cannot see cursor shapes)" or "cursor visible"
      if not state.cursor_hidden then
        -- force an immediate update next frame
        state.cursor_tok = ""
      end
    elseif hovered_btn.id == "poll" then
      local s = window.get_clipboard() or ""
      state.clipboard = s
      state.clipboard_age = 0
      state.clipboard_poll_t = 0
      state.clipboard_msg = "polled clipboard now"
    end
  end
end

local function draw_button(b, hover, down, label_override)
  local label = label_override or b.label
  local fill = hover and C_PANEL or C_PANEL_2
  local border = hover and C_ACCENT or C_LINE
  if down then
    fill = C_PANEL_2
    border = C_WARN
  end
  box(b.x, b.y, b.w, b.h, fill, border)
  draw.text(b.x + 2, b.y + 1, label, hover and C_TEXT or C_MUTED)
end

-- draw_terminal renders the UI + demo world.
function draw_terminal()
  local cols, rows = window.grid_size()
  if cols <= 0 or rows <= 0 then return end

  draw.clear(C_BG)

  local ui = state.ui or compute_ui(cols, rows)
  local panel_w, world_x0, world_x1 = ui.panel_w, ui.world_x0, ui.world_x1
  local world_w = cols - world_x0

  -- left panel background + divider
  if panel_w > 0 then
    draw.rect(0, 0, panel_w, rows, C_PANEL)
    draw.rect(panel_w, 0, 1, rows, C_LINE)
  end

  -- world column background (narrow play space)
  if world_w > 0 then
    draw.rect(world_x0, 0, world_w, rows, C_PANEL_2)
  end

  -- demo entity
  draw.glyph(state.px, state.py, C_ACCENT, "@", 0)

  -- mouse cursor overlay (draw LAST so it's above everything)
  local mx, my = input.mouse_pos()
  if mx >= 0 and mx < cols and my >= 0 and my < rows then
    draw.glyph(mx, my, C_ACCENT, "┼", 0)
  end

  -- left panel content
  local x = 2
  local y = 1

  -- INFO header
  local cell_w, cell_h = window.cell_size()
  draw.text(x, y, "INFO", C_TEXT) ; y = y + 1
  draw.text(x, y, string.format("grid: %d x %d   cell: %d x %d", cols, rows, cell_w, cell_h), C_MUTED) ; y = y + 1
  draw.text(x, y, string.format("world: x=[%d..%d] (w=%d)", world_x0, world_x1, world_w), C_MUTED) ; y = y + 2

  -- CLIPBOARD section
  draw.text(x, y, "CLIPBOARD", C_TEXT) ; y = y + 1

  local hovered_btn = ui and find_button(ui, mx, my) or nil
  local mouse_down = input.mouse_down("left")

  for i = 1, #ui.buttons do
    local b = ui.buttons[i]
    local hover = hovered_btn and (hovered_btn.id == b.id)
    local down = hover and mouse_down
    local label_override = nil
    if b.id == "cursor" then
      label_override = state.cursor_hidden and "show cursor" or "hide cursor"
    end
    draw_button(b, hover, down, label_override)
  end

  local clip_title = string.format("clipboard (%d bytes, %.2fs ago)", #(state.clipboard or ""), state.clipboard_age)
  if state.clipboard_msg ~= "" then
    clip_title = clip_title .. "  -  " .. state.clipboard_msg
  end
  if ui.clip_box.w > 0 then
    draw_boxed_text(ui.clip_box.x, ui.clip_box.y, ui.clip_box.w, ui.clip_box.h, clip_title, (state.clipboard ~= "" and state.clipboard or "<empty>"), C_MUTED, C_TEXT)
  end

  -- continue layout after clipboard region
  y = ui.input_y0

  draw.text(x, y, "INPUT", C_TEXT) ; y = y + 2

  draw.text(x, y, "keys", C_TEXT) ; y = y + 1
  draw.text(x, y, "              D   P   R   Rep", C_MUTED) ; y = y + 1

  row_key_states(x, y, "w", "w") ; y = y + 1
  row_key_states(x, y, "a", "a") ; y = y + 1
  row_key_states(x, y, "s", "s") ; y = y + 1
  row_key_states(x, y, "d", "d") ; y = y + 2

  row_key_states(x, y, "space", "space") ; y = y + 1
  row_key_states(x, y, "enter", "enter") ; y = y + 1
  row_key_states(x, y, "tab", "tab") ; y = y + 1
  row_key_states(x, y, "backspace", "backspace") ; y = y + 2

  draw.text(x, y, "mouse buttons", C_TEXT) ; y = y + 1
  draw.text(x, y, "              D   P   R", C_MUTED) ; y = y + 1
  row_mouse_states(x, y, "left", "left") ; y = y + 1
  row_mouse_states(x, y, "right", "right") ; y = y + 1
  row_mouse_states(x, y, "middle", "middle") ; y = y + 2

  -- boxed text areas
  local box_x = x
  local box_w = panel_w - 4

  local last_h = 5
  local buf_h  = math.max(7, rows - (y + 2) - 3)

  local last_title = string.format("last input (%.2fs ago)", state.last_input_age)
  draw_boxed_text(box_x, y, box_w, last_h, last_title, (state.last_input ~= "" and state.last_input or "<none>"), C_MUTED, C_TEXT)
  y = y + last_h + 1

  draw_boxed_text(box_x, y, box_w, buf_h, "typed buffer", (state.typed ~= "" and state.typed or "<empty>"), C_MUTED, C_WARN)

  -- tiny world column info (keep short; column is narrow)
  if world_w > 0 then
    draw.text(world_x0, 0, "WORLD", C_TEXT)
    draw.text(world_x0, 1, "WASD move", C_MUTED)
    draw.text(world_x0, 2, "LMB tp", C_MUTED)
    draw.text(world_x0, 3, "hover->cursor: crosshair", C_MUTED)
    draw.text(world_x0, rows - 2, "panel divider->resize_ew", C_MUTED)
    draw.text(world_x0, rows - 1, string.format("wheel: %.1f,%.1f", state.wheel_x, state.wheel_y), C_MUTED)
  end
end

