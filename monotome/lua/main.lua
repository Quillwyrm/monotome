local r = monotome.runtime
local d = monotome.draw
local w = monotome.window
local i = monotome.input
local font = monotome.font

local BG   = {  8, 10, 16, 255 }
local DIM  = { 130,150,170,255 }
local TXT  = { 210,230,255,255 }
local OK   = { 120,255,180,255 }
local BAD  = { 255,120,120,255 }

-- button fills
local BTN_BG     = { 18, 22, 34, 255 }
local BTN_BG_HOV = { 26, 32, 48, 255 }
local BTN_BG_ACT = { 34, 44, 64, 255 }

local F   = 1
local FB  = 2

local MAX_BUF = 20000

local PULSE = 0.12
local p = {}
local rep = {}
local rls = {}

local watch = {
  "left","right","up","down",
  "escape","space","return","tab","backspace",
  "lshift","lsuper",
  "a","f1","f2","f3","f4","f8",
  "kp1",
}

local x, y = 10, 8

-- wheel pulse
local W_PULSE = 0.20
local w_p = 0
local w_dx = 0
local w_dy = 0

-- text
local T_PULSE = 0.35
local t_on = false
local t_p = 0
local t_last = ""
local t_acc = ""

-- cursor test (Love names only)
local cursor_names = {
  "arrow","ibeam","hand","crosshair","wait","waitarrow",
  "sizewe","sizens","sizenwse","sizenesw","sizeall","no",
}
local cursor_idx = 1
local cursor_last = cursor_names[cursor_idx]
local cursor_err = ""
local cursor_hidden = false

-- clipboard
local clip_last_set = 0
local clip_last_get = 0
local clip_err = ""

-- font size test
local font_err = ""
local font_req_delta = 0
local font_step = 1

local blink = 0

local function utf8_pop(s)
  local n = #s
  if n == 0 then return s end
  local j = n
  while j > 0 do
    local b = s:byte(j)
    if b < 0x80 or b >= 0xC0 then break end
    j = j - 1
  end
  if j <= 0 then return "" end
  return s:sub(1, j - 1)
end

local function one_line(s, max)
  s = s:gsub("\r","\\r"):gsub("\n","\\n"):gsub("\t","\\t")
  if #s > max then s = s:sub(1, max - 3) .. "..." end
  return s
end

local function decay_map(m, dt)
  for k,v in pairs(m) do
    v = v - dt
    if v <= 0 then m[k] = nil else m[k] = v end
  end
end

local function decay_val(v, dt)
  if v > 0 then
    v = v - dt
    if v < 0 then v = 0 end
  end
  return v
end

local function safe_pcall(fn)
  local ok, res = pcall(fn)
  if ok then return true, res end
  return false, tostring(res)
end

-- ------------------------------------------------------------
-- Flat button: single rect behind a label (no border).
-- Height = 1 row.
-- ------------------------------------------------------------
local function button_row(col, row, w0, label, active)
  local mc, mr = i.mouse_position()
  local hover = (mr == row) and (mc >= col) and (mc < col + w0)

  local bg = BTN_BG
  if active then bg = BTN_BG_ACT end
  if hover then bg = BTN_BG_HOV end

  d.rect(col, row, w0, 1, bg)

  local inner = w0 - 2
  local s = label
  if #s > inner then
    s = s:sub(1, math.max(0, inner - 3)) .. "..."
  end
  d.text(col + 1, row, s, TXT, FB)

  return hover and i.pressed("mouse1")
end

local function clamp_buf()
  if #t_acc > MAX_BUF then
    t_acc = t_acc:sub(#t_acc - MAX_BUF + 1)
  end
end

local function cursor_cycle()
  cursor_err = ""
  cursor_idx = cursor_idx + 1
  if cursor_idx > #cursor_names then cursor_idx = 1 end
  local name = cursor_names[cursor_idx]
  local ok, err = safe_pcall(function() w.set_cursor(name) end)
  if ok then cursor_last = name else cursor_err = err end
end

local function cursor_toggle_visible()
  cursor_err = ""
  local ok, err = safe_pcall(function()
    if cursor_hidden then
      w.cursor_show()
      cursor_hidden = false
    else
      w.cursor_hide()
      cursor_hidden = true
    end
  end)
  if not ok then cursor_err = err end
end

local function clipboard_copy_all()
  clip_err = ""
  local payload = t_acc
  local ok, err = safe_pcall(function() w.set_clipboard(payload) end)
  if ok then
    clip_last_set = #payload
  else
    clip_err = err
  end
end

local function clipboard_paste_append()
  clip_err = ""
  local ok, res = safe_pcall(function() return w.get_clipboard() end)
  if ok then
    local s = res or ""
    clip_last_get = #s
    if s ~= "" then
      t_acc = t_acc .. s
      clamp_buf()
      t_p = T_PULSE
      t_last = "<paste>"
    end
  else
    clip_err = res
  end
end

local function text_clear()
  t_acc = ""
  t_p = T_PULSE
  t_last = "<clear>"
end

local function text_toggle()
  if t_on then
    pcall(i.stop_text)
    t_on = false
  else
    local ok = pcall(i.start_text)
    if ok then t_on = true end
  end
end

function r.init()
  w.init(1920, 1080, "monotome api test", { "resizable" })

  -- start text input ON once (no auto-forcing in update)
  local ok = pcall(i.start_text)
  t_on = ok and true or false

  local okc, err = safe_pcall(function() w.set_cursor("arrow") end)
  if not okc then cursor_err = err end
end

function r.update(dt)
  blink = blink + dt

  decay_map(p, dt)
  decay_map(rep, dt)
  decay_map(rls, dt)
  w_p = decay_val(w_p, dt)
  t_p = decay_val(t_p, dt)

  for n = 1, #watch do
    local k = watch[n]
    if i.pressed(k) then p[k] = PULSE end
    if i.repeated(k)  then rep[k] = PULSE end
    if i.released(k)  then rls[k] = PULSE end
  end

  if i.pressed("mouse1") then p["mouse1"] = PULSE end
  if i.released("mouse1") then rls["mouse1"] = PULSE end

  -- quit request
  if i.pressed("escape") then pcall(w.close) end

  -- wheel
  local dx, dy = i.mouse_wheel()
  if dx ~= 0 or dy ~= 0 then
    w_p = W_PULSE
    w_dx = dx
    w_dy = dy
  end

  -- key toggle still available
  if i.pressed("f2") then text_toggle() end

  local chunk = i.text()
  if chunk ~= "" then
    t_p = T_PULSE
    t_last = chunk
    t_acc = t_acc .. chunk
    clamp_buf()
  end

  if i.pressed("backspace") or i.repeated("backspace") then
    t_p = T_PULSE
    t_last = "<bs>"
    t_acc = utf8_pop(t_acc)
  end

  -- apply requested font size change (requested during draw)
  if font_req_delta ~= 0 then
    font_err = ""
    local ok0, cur = safe_pcall(function() return font.size() end)
    if ok0 then
      cur = tonumber(cur) or 1
      local next_size = cur + font_req_delta
      if next_size < 1 then next_size = 1 end

      local ok1, err1 = safe_pcall(function() font.set_size(next_size) end)
      if not ok1 then font_err = err1 end
    else
      font_err = cur
    end

    font_req_delta = 0
  end

  -- move marker
  local step = i.down("lshift") and 4 or 1
  if i.pressed("left")  then x = x - step end
  if i.pressed("right") then x = x + step end
  if i.pressed("up")    then y = y - step end
  if i.pressed("down")  then y = y + step end

  local cols, rows = w.grid_size()
  if x < 0 then x = 0 end
  if y < 0 then y = 0 end
  if cols > 0 and x > cols - 1 then x = cols - 1 end
  if rows > 0 and y > rows - 1 then y = rows - 1 end
end

function r.draw()
  d.clear(BG)

  local cols, rows = w.grid_size()

  local panel_w = 46
  local px = cols - panel_w
  if px < 1 then px = 1 end

  local on  = "o"
  local off = "·"

  -- ------------------------------------------------------------
  -- WINDOW GETTERS
  -- ------------------------------------------------------------
  local ww, wh = w.size()
  local wx, wy = w.position()
  local cw, ch = w.cell_size()
  local m_cols, m_rows, m_cw, m_ch, m_ww, m_wh, m_wx, m_wy = w.metrics()
  local metrics_ok = (m_cols == cols and m_rows == rows and m_cw == cw and m_ch == ch and m_ww == ww and m_wh == wh and m_wx == wx and m_wy == wy)

  local row = 0
  d.text(px, row, "WINDOW (getters)", DIM, FB) ; row = row + 1
  d.text(px, row, "size:", TXT, FB)
  d.text(px + 7, row, tostring(ww) .. "x" .. tostring(wh), OK, F) ; row = row + 1
  d.text(px, row, "grid:", TXT, FB)
  d.text(px + 7, row, tostring(cols) .. "x" .. tostring(rows), OK, F) ; row = row + 1
  d.text(px, row, "pos:", TXT, FB)
  d.text(px + 7, row, tostring(wx) .. "," .. tostring(wy), OK, F) ; row = row + 1
  d.text(px, row, "cell:", TXT, FB)
  d.text(px + 7, row, tostring(cw) .. "x" .. tostring(ch), OK, F) ; row = row + 1
  d.text(px, row, "metrics:", TXT, FB)
  d.text(px + 10, row, metrics_ok and "OK" or "MISMATCH", metrics_ok and OK or BAD, F) ; row = row + 2

  -- ------------------------------------------------------------
  -- ACTION ROWS (single-rect buttons)
  -- ------------------------------------------------------------
  d.text(px, row, "ACTIONS (click)", DIM, FB) ; row = row + 1

  local bw = panel_w - 2
  local bx = px + 1

  -- font controls
  local ok_fs, fs = safe_pcall(function() return font.size() end)
  fs = ok_fs and (tonumber(fs) or 0) or 0

  d.text(px, row, "font size:", TXT, FB)
  d.text(px + 11, row, tostring(fs), OK, F)
  row = row + 1

  if button_row(bx, row, bw, "Font size - (" .. tostring(font_step) .. ")", false) then
    font_req_delta = font_req_delta - font_step
  end
  row = row + 1

  if button_row(bx, row, bw, "Font size + (" .. tostring(font_step) .. ")", false) then
    font_req_delta = font_req_delta + font_step
  end
  row = row + 1

  if font_err ~= "" then
    d.text(px, row, one_line(font_err, panel_w - 1), BAD, F)
    row = row + 1
  end

  if button_row(bx, row, bw, "Cursor: cycle (" .. cursor_last .. ")", false) then
    cursor_cycle()
  end
  row = row + 1

  if button_row(bx, row, bw, "Cursor: " .. (cursor_hidden and "show" or "hide"), false) then
    cursor_toggle_visible()
  end
  row = row + 1

  local vis = false
  local ok_vis, res_vis = safe_pcall(function() return w.cursor_visible() end)
  if ok_vis then vis = (res_vis == true) end

  d.text(px, row, "cursor_visible:", TXT, FB)
  d.text(px + 16, row, vis and on or off, vis and OK or DIM, F)
  row = row + 1

  if cursor_err ~= "" then
    d.text(px, row, one_line(cursor_err, panel_w - 1), BAD, F)
    row = row + 1
  end

  if button_row(bx, row, bw, "Clipboard: COPY (whole textbox)", false) then
    clipboard_copy_all()
  end
  row = row + 1

  if button_row(bx, row, bw, "Clipboard: PASTE (append)", false) then
    clipboard_paste_append()
  end
  row = row + 1

  d.text(px, row, "clip set bytes:", TXT, FB)
  d.text(px + 15, row, tostring(clip_last_set), OK, F)
  row = row + 1

  d.text(px, row, "clip get bytes:", TXT, FB)
  d.text(px + 15, row, tostring(clip_last_get), OK, F)
  row = row + 1

  if clip_err ~= "" then
    d.text(px, row, one_line(clip_err, panel_w - 1), BAD, F)
    row = row + 1
  end

  if button_row(bx, row, bw, "Text Input: " .. (t_on and "ON" or "OFF") .. " (F2)", t_on) then
    text_toggle()
  end
  row = row + 1

  if button_row(bx, row, bw, "Text: CLEAR", false) then
    text_clear()
  end
  row = row + 2

  -- ------------------------------------------------------------
  -- INPUT WATCH (kept)
  -- ------------------------------------------------------------
  d.text(px, row, "INPUT  D P Rp R", DIM, FB) ; row = row + 2

  for n = 1, #watch do
    local k = watch[n]
    local dn = i.down(k)
    local pr = (p[k] ~= nil)
    local rp = (rep[k] ~= nil)
    local rl = (rls[k] ~= nil)

    d.text(px, row, k, TXT, F)
    d.text(px + 13, row, dn and on or off, dn and OK or DIM, F)
    d.text(px + 15, row, pr and on or off, pr and OK or DIM, F)
    d.text(px + 18, row, rp and on or off, rp and OK or DIM, F)
    d.text(px + 21, row, rl and on or off, rl and OK or DIM, F)
    row = row + 1
  end

  row = row + 1
  local mc, mr = i.mouse_position()
  d.text(px, row, "mouse_pos:", TXT, FB)
  d.text(px + 11, row, tostring(mc) .. "," .. tostring(mr), OK, F)
  row = row + 1

  d.text(px, row, "wheel:", TXT, FB)
  if w_p > 0 then
    d.text(px + 7, row, tostring(w_dx) .. "," .. tostring(w_dy), OK, F)
  else
    d.text(px + 7, row, "0,0", DIM, F)
  end
  row = row + 1

  d.text(px, row, "text:", TXT, FB)
  d.text(px + 7, row, t_on and on or off, t_on and OK or DIM, F)
  if t_p > 0 then
    d.text(px + 9, row, one_line(t_last, panel_w - 10), OK, F)
  else
    d.text(px + 9, row, "(none)", DIM, F)
  end

  -- ------------------------------------------------------------
  -- TEXTBOX (left)
  -- ------------------------------------------------------------
  local bx2 = 1
  local by2 = 1
  local bw2 = px - 3
  local bh2 = rows - 3
  if bw2 < 8 then bw2 = 8 end
  if bh2 < 6 then bh2 = 6 end

  d.rect(bx2, by2, bw2, bh2, { 12, 14, 20, 255 })

  local cap = (bw2 - 2) * (bh2 - 2)
  local s = t_acc
  if #s > cap then s = s:sub(#s - cap + 1) end

  local caret = ((math.floor(blink * 2) % 2) == 0) and "|" or " "
  s = s .. caret

  local idx = 1
  for yy = 0, bh2 - 3 do
    if idx > #s then break end
    local line = s:sub(idx, idx + (bw2 - 3))
    idx = idx + (bw2 - 2)
    d.text(bx2 + 1, by2 + 1 + yy, line, OK, F)
  end

  d.text(x, y, "@", OK, FB)
end

