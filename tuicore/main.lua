-- main.lua (LuaJIT-safe cyberpunk stress test)
-- Pushes: full-screen backgrounds + matrix rain + HUD + bursts.
-- Uses only: ASCII + box/block glyphs your bake list already includes.

local t = 0

local cols, rows = 0, 0
local head = {}
local speed = {}
local seed = {}

local function clamp(x, a, b)
  if x < a then return a end
  if x > b then return b end
  return x
end

local function rgba(r,g,b,a)
  return { clamp(r,0,255), clamp(g,0,255), clamp(b,0,255), a or 255 }
end

-- cheap integer-ish RNG (LCG) that works fine on LuaJIT numbers
local function lcg(s)
  -- constants chosen for decent scatter
  s = (s * 1664525 + 1013904223) % 4294967296
  return s
end

local RAIN = "abcdefghijklmnopqrstuvwxyz0123456789@#$%&*+?;:,.=<>[]{}()\\|/"

local function putstr(x, y, col, s, face)
  for i = 1, #s do
    draw.glyph(x + (i-1), y, col, s:sub(i,i), face or 0)
  end
end

local function frame(x0,y0,x1,y1,col,face)
  if x1 <= x0 or y1 <= y0 then return end
  draw.glyph(x0,y0,col,"┌",face); draw.glyph(x1,y0,col,"┐",face)
  draw.glyph(x0,y1,col,"└",face); draw.glyph(x1,y1,col,"┘",face)
  for x = x0+1, x1-1 do
    draw.glyph(x,y0,col,"─",face)
    draw.glyph(x,y1,col,"─",face)
  end
  for y = y0+1, y1-1 do
    draw.glyph(x0,y,col,"│",face)
    draw.glyph(x1,y,col,"│",face)
  end
end

local function resize_state()
  cols = TERM_COLS or 0
  rows = TERM_ROWS or 0

  head, speed, seed = {}, {}, {}
  if cols <= 0 or rows <= 0 then return end

  for x = 0, cols-1 do
    local s = (x+1) * 1337 + 12345
    seed[x]  = s % 4294967296
    head[x]  = (s % rows)
    speed[x] = 8 + (s % 24) -- 8..31 cells/sec
  end
end

function init_terminal()
  t = 0
  resize_state()
end

function update_terminal(dt)
  t = t + (dt or 0)

  local c = TERM_COLS or 0
  local r = TERM_ROWS or 0
  if c ~= cols or r ~= rows then
    resize_state()
  end

  if cols <= 0 or rows <= 0 then return end

  for x = 0, cols-1 do
    -- wobble speed a bit without bit ops
    local s = seed[x]
    s = lcg(s + math.floor(t*60))
    seed[x] = s
    local wob = (s % 1000) / 1000

    local v = speed[x] * (0.85 + 0.30*wob)
    head[x] = (head[x] + v * (dt or 0)) % rows
  end
end

function draw_terminal()
  draw.clear(rgba(6,6,10,255))
  if cols <= 0 or rows <= 0 then return end

  local deep  = rgba(6,6,10,255)
  local bgA   = rgba(10,10,18,255)
  local bgB   = rgba(14,12,24,255)

  local cyan  = rgba(80,255,240,255)
  local mag   = rgba(255,80,220,255)
  local lime  = rgba(80,255,120,255)
  local white = rgba(240,240,255,255)

  -- background: scanlines + shimmer bands (heavy)
  local band1 = math.floor((math.sin(t*0.8)*0.5 + 0.5) * (rows-1))
  local band2 = math.floor((math.sin(t*1.3+1.7)*0.5 + 0.5) * (rows-1))

  for y = 0, rows-1 do
    local scan = ((y + math.floor(t*50)) % 6) == 0
    local u = 0.10
    if y == band1 then u = 0.75
    elseif y == band2 then u = 0.55
    elseif scan then u = 0.22
    end

    local row = (u > 0.5) and bgB or bgA
    for x = 0, cols-1 do
      if ((x + y) % 2) == 0 then
        draw.cell(x,y,row)
      else
        draw.cell(x,y,deep)
      end
    end
  end

  -- matrix rain (glyph heavy)
  for x = 0, cols-1 do
    local hy = math.floor(head[x])
    local s = seed[x]
    local tail = 12 + (s % 20)

    for i = 0, tail do
      local yy = (hy - i) % rows

      s = lcg(s + yy*733 + x*97 + math.floor(t*30))
      local idx = (s % #RAIN) + 1
      local ch = RAIN:sub(idx, idx)

      local f = 1.0 - (i / (tail+1))
      f = f*f

      local col
      if i == 0 then col = white
      elseif i < 3 then col = rgba(160,255,200,255)
      else
        col = rgba(
          math.floor(lerp(6,  80, f) + 0.5),
          math.floor(lerp(6, 255, f) + 0.5),
          math.floor(lerp(10,120, f) + 0.5),
          255
        )
      end

      draw.glyph(x, yy, col, ch, 0)
    end
  end

  -- HUD frame + labels
  local pad = 1
  local frame_col = ((math.sin(t*2.0)*0.5 + 0.5) > 0.5) and cyan or mag
  frame(pad,pad, cols-1-pad, rows-1-pad, frame_col, 0)

  putstr(3, 1, cyan, "QTERM // CYBER STRESS (LuaJIT)", 0)

  -- crosshair
  local cx = math.floor((math.sin(t*0.9)*0.5 + 0.5) * (cols-1))
  local cy = math.floor((math.sin(t*1.1+2.1)*0.5 + 0.5) * (rows-1))
  local cross = ((math.sin(t*3.3)*0.5 + 0.5) > 0.5) and cyan or mag

  for dx = -8, 8 do
    local x = cx + dx
    if x >= 1 and x < cols-1 and cy >= 1 and cy < rows-1 and dx ~= 0 then
      draw.glyph(x, cy, cross, "─", 0)
    end
  end
  for dy = -4, 4 do
    local y = cy + dy
    if y >= 1 and y < rows-1 and cx >= 1 and cx < cols-1 and dy ~= 0 then
      draw.glyph(cx, y, cross, "│", 0)
    end
  end
  if cx >= 1 and cx < cols-1 and cy >= 1 and cy < rows-1 then
    draw.glyph(cx, cy, white, "┼", 0)
  end

  -- burst blocks (█)
  local burst = (math.sin(t*4.0) * 0.5 + 0.5)
  if burst > 0.92 then
    local bx = math.floor((math.sin(t*2.3+0.7)*0.5 + 0.5) * (cols-6)) + 3
    local by = math.floor((math.sin(t*2.9+1.2)*0.5 + 0.5) * (rows-6)) + 3
    for yy = -2, 2 do
      for xx = -5, 5 do
        local x = bx + xx
        local y = by + yy
        if x >= 1 and x < cols-1 and y >= 1 and y < rows-1 then
          local u = 1.0 - (math.abs(xx)/5.0)
          local c = rgba(
            math.floor(lerp(80, 255, u*0.8) + 0.5),
            80,
            math.floor(lerp(220, 255, u*0.6) + 0.5),
            255
          )
          draw.glyph(x, y, c, "█", 0)
        end
      end
    end
  end
end

-- tiny helper used above (kept global to avoid forward decl noise)
function lerp(a,b,u) return a + (b-a)*u end

