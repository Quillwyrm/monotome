local r = monotome.runtime
local d = monotome.draw
local w = monotome.window
local i = monotome.input

local BG  = { 8, 10, 16, 255 }
local DIM = { 130, 150, 170, 255 }
local TXT = { 210, 230, 255, 255 }
local OK  = { 120, 255, 180, 255 }
local F   = 1
local FB  = 2

local PULSE = 0.12
local p = {}
local rep = {}
local rls = {}

local watch = {
  "left","right","up","down",
  "escape","space","return","tab","backspace",
  "lshift","lsuper",
  "a","f1","f2","kp1",
}

local x, y = 10, 8

local W_PULSE = 0.20
local w_p = 0
local w_dx = 0
local w_dy = 0

local T_PULSE = 0.35
local t_on = false
local t_p = 0
local t_last = ""
local t_acc = ""

local blink = 0

local function utf8_pop(s)
  local n = #s
  if n == 0 then return s end
  local i = n
  while i > 0 do
    local b = s:byte(i)
    if b < 0x80 or b >= 0xC0 then break end
    i = i - 1
  end
  if i <= 0 then return "" end
  return s:sub(1, i - 1)
end

function r.init()
  w.init(900, 520, "input", { "resizable" })
end

function r.update(dt)
  blink = blink + dt

  for k,v in pairs(p) do v = v - dt; if v <= 0 then p[k] = nil else p[k] = v end end
  for k,v in pairs(rep) do v = v - dt; if v <= 0 then rep[k] = nil else rep[k] = v end end
  for k,v in pairs(rls) do v = v - dt; if v <= 0 then rls[k] = nil else rls[k] = v end end
  if w_p > 0 then w_p = w_p - dt; if w_p < 0 then w_p = 0 end end
  if t_p > 0 then t_p = t_p - dt; if t_p < 0 then t_p = 0 end end

  for n = 1, #watch do
    local k = watch[n]
    if i.pressed(k) then p[k] = PULSE end
    if i.repeated(k)  then rep[k] = PULSE end
    if i.released(k) then rls[k] = PULSE end
  end

  if i.pressed("mouse1") then p["mouse1"] = PULSE end
  if i.released("mouse1") then rls["mouse1"] = PULSE end
  if i.pressed("mouse2") then p["mouse2"] = PULSE end
  if i.released("mouse2") then rls["mouse2"] = PULSE end
  if i.pressed("mouse3") then p["mouse3"] = PULSE end
  if i.released("mouse3") then rls["mouse3"] = PULSE end

  local dx, dy = i.mouse_wheel()
  if dx ~= 0 or dy ~= 0 then
    w_p = W_PULSE
    w_dx = dx
    w_dy = dy
  end

  if not t_on then
    local ok = pcall(i.start_text)
    if ok then t_on = true end
  end

  if i.pressed("f2") then
    if t_on then
      pcall(i.stop_text)
      t_on = false
    else
      local ok = pcall(i.start_text)
      if ok then t_on = true end
    end
  end

  local chunk = i.text()
  if chunk ~= "" then
    t_p = T_PULSE
    t_last = chunk
    t_acc = t_acc .. chunk
    if #t_acc > 4000 then
      t_acc = t_acc:sub(#t_acc - 3999)
    end
  end

  if i.pressed("backspace") or i.repeated("backspace") then
    t_p = T_PULSE
    t_last = "<bs>"
    t_acc = utf8_pop(t_acc)
  end

  local step = i.down("lshift") and 4 or 1
  if i.pressed("left")  then x = x - step end
  if i.pressed("right") then x = x + step end
  if i.pressed("up")    then y = y - step end
  if i.pressed("down")  then y = y + step end

  local cols = w.columns()
  local rows = w.rows()
  if x < 0 then x = 0 end
  if y < 0 then y = 0 end
  if cols > 0 and x > cols - 1 then x = cols - 1 end
  if rows > 0 and y > rows - 1 then y = rows - 1 end
end

function r.draw()
  d.clear(BG)

  local cols = w.columns()
  local rows = w.rows()

  local panel_w = 28
  local px = cols - panel_w
  if px < 1 then px = 1 end

  local on  = "o"
  local off = "·"

  d.text(px, 0, "D P Rp R     F2=text", DIM, F)

  local row = 2
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
  d.text(px, row, "mouse1 mouse2 mouse3", TXT, FB)
  row = row + 1

  for n = 1, 3 do
    local k = "mouse" .. tostring(n)
    local dn = i.down(k)
    local pr = (p[k] ~= nil)
    local rl = (rls[k] ~= nil)

    d.text(px, row, k, TXT, F)
    d.text(px + 13, row, dn and on or off, dn and OK or DIM, F)
    d.text(px + 15, row, pr and on or off, pr and OK or DIM, F)
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
    d.text(px + 9, row, t_last, OK, F)
  else
    d.text(px + 9, row, "(none)", DIM, F)
  end

  -- textbox (left side)
  local bx = 1
  local by = 1
  local bw = px - 3
  local bh = rows - 3
  if bw < 8 then bw = 8 end
  if bh < 6 then bh = 6 end

  local top = "+" .. string.rep("-", bw - 2) .. "+"
  local mid = "|" .. string.rep(" ", bw - 2) .. "|"
  local bot = top

  d.text(bx, by, top, DIM, F)
  for yy = 1, bh - 2 do
    d.text(bx, by + yy, mid, DIM, F)
  end
  d.text(bx, by + bh - 1, bot, DIM, F)

  local cap = (bw - 2) * (bh - 2)
  local s = t_acc
  if #s > cap then
    s = s:sub(#s - cap + 1)
  end

  local caret = ((math.floor(blink * 2) % 2) == 0) and "|" or " "
  s = s .. caret

  local idx = 1
  for yy = 0, bh - 3 do
    if idx > #s then break end
    local line = s:sub(idx, idx + (bw - 3))
    idx = idx + (bw - 2)
    d.text(bx + 1, by + 1 + yy, line, OK, F)
  end

  d.text(x, y, "@", OK, FB)
end

