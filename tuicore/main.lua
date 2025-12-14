-- main.lua
-- no-vim: mock editor benchmark scene (cell background + glyph foreground)
--
-- Goal:
-- - hammer draw.cell + draw.glyph in a way that resembles a real editor UI
-- - left tree panel, top bar, status bar, code view, minimap-ish gutter
-- - lots of repeated patterns + some scrolling + a blinking cursor
--
-- Notes:
-- - Uses UTF-8 safe iteration for drawing strings.
-- - Assumes TERM_COLS / TERM_ROWS are provided by tuicore.

local t = 0

local function rgba(r,g,b,a) return {r,g,b,a or 255} end

-- UTF-8 iterator (codepoint by codepoint, not byte slicing)
local function utf8_iter(s)
  local i, n = 1, #s
  return function()
    if i > n then return nil end
    local c = s:byte(i)
    local len
    if c < 0x80 then len = 1
    elseif c < 0xE0 then len = 2
    elseif c < 0xF0 then len = 3
    else len = 4 end
    local ch = s:sub(i, i + len - 1)
    i = i + len
    return ch
  end
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function draw_text(x, y, col, s, face, max_cols)
  face = face or 0
  local cx = x
  local limit = max_cols or 10^9
  for ch in utf8_iter(s) do
    if cx - x >= limit then break end
    draw.glyph(cx, y, col, ch, face)
    cx = cx + 1
  end
end

local function fill_rect(x0, y0, w, h, col)
  for y = y0, y0 + h - 1 do
    for x = x0, x0 + w - 1 do
      draw.cell(x, y, col)
    end
  end
end

local function hline(x0, y, w, col, ch)
  ch = ch or "─"
  for x = x0, x0 + w - 1 do
    draw.glyph(x, y, col, ch, 0)
  end
end

local function vline(x, y0, h, col, ch)
  ch = ch or "│"
  for y = y0, y0 + h - 1 do
    draw.glyph(x, y, col, ch, 0)
  end
end

local function box(x0, y0, w, h, col)
  if w < 2 or h < 2 then return end
  draw.glyph(x0,     y0,     col, "┌", 0)
  draw.glyph(x0+w-1, y0,     col, "┐", 0)
  draw.glyph(x0,     y0+h-1, col, "└", 0)
  draw.glyph(x0+w-1, y0+h-1, col, "┘", 0)
  hline(x0+1, y0,     w-2, col, "─")
  hline(x0+1, y0+h-1, w-2, col, "─")
  vline(x0,     y0+1, h-2, col, "│")
  vline(x0+w-1, y0+1, h-2, col, "│")
end

-- Cheap pseudo-rand (deterministic) - LuaJIT bitops (Lua 5.1)
local bit = bit or require("bit")
local bxor   = bit.bxor
local lshift = bit.lshift
local rshift = bit.rshift
local tobit  = bit.tobit

local function hash(n)
  n = tobit(n)
  n = bxor(n, lshift(n, 13))
  n = bxor(n, rshift(n, 17))
  n = bxor(n, lshift(n, 5))
  return n
end

local function pick(list, n)
  return list[(n % #list) + 1]
end

-- ---------------------------------------------------------------------

function init_terminal()
  t = 0
end

function update_terminal(dt)
  t = t + (dt or 0)
end

-- ---------------------------------------------------------------------
-- UI model (static-ish content)
-- ---------------------------------------------------------------------

local tree_items = {
  "no-vim/",
  "  src/",
  "    main.lua",
  "    editor.lua",
  "    render.lua",
  "    buffer.lua",
  "    utf8.lua",
  "  docs/",
  "    spec.md",
  "    roadmap.md",
  "  assets/",
  "    icon.ttf",
  "  README.md",
}

local code_lines = {
  "local function draw_glyph(x, y, fg, ch, face)",
  "  -- crop to cell to prevent bleed/overlap",
  "  -- face fallback: only BASE_CODEPOINTS use italic/bold",
  "  -- everything else forced to regular to guarantee glyph presence",
  "  if not is_base_codepoint(ch) then face = 0 end",
  "  return blit(ch, x, y, fg, face)",
  "end",
  "",
  "local function paint_editor()",
  "  draw_status(\"no-vim\", \"NORMAL\", cursor, diagnostics)",
  "  draw_tree(tree, selection)",
  "  draw_doc(buffer, scroll, cursor)",
  "end",
  "",
  "-- UTF-8 note: never byte-slice strings",
  "for ch in utf8_iter(s) do",
  "  draw.glyph(cx, y, fg, ch, face)",
  "end",
}

local keywords = {
  ["local"]=true, ["function"]=true, ["end"]=true, ["if"]=true, ["then"]=true,
  ["for"]=true, ["in"]=true, ["do"]=true, ["return"]=true, ["not"]=true,
}

local function color_token(tok)
  if keywords[tok] then return rgba(255, 130, 140) end
  if tok:match("^%-%-") then return rgba(120, 200, 140) end
  if tok:match("^\"") or tok:match("^'") then return rgba(140, 220, 255) end
  if tok:match("^%d") then return rgba(255, 210, 140) end
  return rgba(220, 220, 220)
end

local function tokenize(line)
  -- super dumb tokenizer: split by spaces, keep punctuation attached.
  local out = {}
  for tok in line:gmatch("%S+") do
    out[#out+1] = tok
  end
  return out
end

-- ---------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------

function draw_terminal()
  local cols = TERM_COLS or 0
  local rows = TERM_ROWS or 0
  if cols <= 0 or rows <= 0 then return end

  -- Layout
  local top_h = 2
  local status_h = 1
  local tree_w = clamp(math.floor(cols * 0.28), 18, 36)
  local gutter_w = 6
  local minimap_w = 8

  local content_y0 = top_h
  local content_y1 = rows - status_h
  local content_h  = content_y1 - content_y0

  local tree_x0 = 0
  local tree_x1 = tree_w

  local doc_x0 = tree_x1
  local doc_x1 = cols - minimap_w
  local doc_w  = doc_x1 - doc_x0

  local mini_x0 = cols - minimap_w

  -- Colors (cyber-ish)
  local bg        = rgba(7, 8, 10)
  local panel_bg  = rgba(10, 11, 16)
  local panel_bg2 = rgba(12, 13, 20)
  local bar_bg    = rgba(18, 16, 24)
  local status_bg = rgba(14, 14, 18)
  local border    = rgba(80, 90, 120)
  local accent    = rgba(120, 255, 220)
  local warn      = rgba(255, 190, 120)
  local err       = rgba(255, 120, 140)
  local dim       = rgba(120, 130, 150)
  local text      = rgba(220, 220, 220)

  -- Base clear
  draw.clear(bg)

  -- Base layer: fill panels (cells)
  fill_rect(0, 0, cols, rows, bg)
  fill_rect(0, 0, cols, top_h, bar_bg)
  fill_rect(0, rows-status_h, cols, status_h, status_bg)

  fill_rect(tree_x0, content_y0, tree_w, content_h, panel_bg)
  fill_rect(doc_x0,  content_y0, doc_w,  content_h, panel_bg2)
  fill_rect(mini_x0, content_y0, minimap_w, content_h, panel_bg)

  -- Panel separators (glyph)
  vline(tree_x1-1, content_y0, content_h, border, "│")
  vline(doc_x1,    content_y0, content_h, border, "│")
  hline(0, top_h-1, cols, border, "─")
  hline(0, rows-status_h, cols, border, "─")

  -- Top bar text
  draw_text(2, 0, accent, "no-vim", 1)
  draw_text(10, 0, dim, "  a monospace editor with a mouse", 0)
  draw_text(cols-28, 0, warn, "CTRL+P  Find File", 0)

  -- Fake tabs
  local tab = "[main.lua]"
  draw_text(2, 1, rgba(255,255,255), tab, 0)
  draw_text(2 + #tab + 2, 1, dim, "[editor.lua] [buffer.lua]", 0)

  -- Tree view
  draw_text(2, content_y0, dim, "PROJECT", 0)
  local tree_scroll = math.floor((math.sin(t*0.6)*0.5+0.5) * 3)
  for i=1, #tree_items do
    local y = content_y0 + 2 + (i-1) - tree_scroll
    if y >= content_y0+1 and y < content_y1-1 then
      local line = tree_items[i]
      local col = (i == 3) and accent or text
      draw_text(1, y, col, line, 0, tree_w-2)
    end
  end

  -- Document gutter + code
  local scroll = math.floor((t*6) % 1000)
  local first_line = scroll
  local cursor_line = first_line + math.floor(content_h * 0.45)
  local cursor_col  = 20 + math.floor((math.sin(t*2.0)*0.5+0.5) * 16)

  draw_text(doc_x0+2, content_y0, dim, "main.lua", 0)

  for row=0, content_h-2 do
    local y = content_y0 + 1 + row
    if y >= content_y1 then break end

    local line_no = first_line + row + 1
    local ln = string.format("%4d", line_no)
    draw_text(doc_x0, y, dim, ln, 0, gutter_w-1)
    draw.glyph(doc_x0+gutter_w-1, y, border, "│", 0)

    local src = code_lines[(line_no % #code_lines) + 1]
    local toks = tokenize(src)

    local x = doc_x0 + gutter_w + 1
    for _,tok in ipairs(toks) do
      local c = color_token(tok)
      draw_text(x, y, c, tok, 0)
      x = x + #tok + 1
      if x >= doc_x1-2 then break end
      draw.glyph(x-1, y, text, " ", 0)
    end

    if (line_no % 19) == 0 then
      draw_text(doc_x1-22, y, err, "!! type mismatch", 0)
    elseif (line_no % 23) == 0 then
      draw_text(doc_x1-20, y, warn, "!! unused var", 0)
    end
  end

  -- Cursor (blink)
  local blink = (math.floor(t*2) % 2) == 0
  if blink then
    local cx = doc_x0 + gutter_w + 1 + cursor_col
    local cy = content_y0 + 1 + (cursor_line - first_line)
    if cy >= content_y0+1 and cy < content_y1-1 and cx < doc_x1-1 then
      draw.cell(cx, cy, rgba(255,255,255,40))
      draw.glyph(cx, cy, rgba(255,255,255), "█", 0)
    end
  end

  -- Minimap-ish: dense columns of block chars
  local blocks = {"░","▒","▓","█"}
  for y = content_y0, content_y1-1 do
    for x = mini_x0, cols-1 do
      local n = hash((x+1)*1315423911 + (y+1)*2654435761 + math.floor(t*10))
      local ch = pick(blocks, n)
      local c1 = ((n % 7) == 0) and rgba(255,120,140) or rgba(120,255,220)
      draw.glyph(x, y, c1, ch, 2) -- request italic: should still render regular for these glyphs
    end
  end

  -- Status bar
  local mode = "NORMAL"
  local pos  = string.format("Ln %d, Col %d", cursor_line, cursor_col)
  local diag = string.format("%dW %dE", (scroll % 7), (scroll % 3))
  draw_text(2, rows-status_h, accent, "no-vim", 1)
  draw_text(10, rows-status_h, dim, mode, 0)
  draw_text(cols-#pos-2, rows-status_h, text, pos, 0)
  draw_text(cols-#pos-#diag-6, rows-status_h, warn, diag, 0)

  -- Neon corner brackets
  box(0, top_h, tree_w, content_h, rgba(60, 80, 110))
  box(doc_x0, top_h, doc_w, content_h, rgba(60, 80, 110))
end

