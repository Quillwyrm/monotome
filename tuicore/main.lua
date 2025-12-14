-- main.lua
-- no-vim: mock editor benchmark scene (LiteXL-like palette)
--
-- Goal:
-- - Approximate a real code editor workload (mostly glyphs, a few highlight rectangles).
-- - Avoid "double painting" (no full-screen cell fill after clear).
-- - Keep panel dividers clean (no text overwriting box-drawing chars).
--
-- Notes:
-- - Uses UTF-8-safe iteration for drawing strings.
-- - Assumes TERM_COLS / TERM_ROWS are provided by tuicore.

local t = 0

local function rgba(r,g,b,a) return {r,g,b,a or 255} end
local function hex(h)
  h = h:gsub("#","")
  local r = tonumber(h:sub(1,2), 16)
  local g = tonumber(h:sub(3,4), 16)
  local b = tonumber(h:sub(5,6), 16)
  return {r,g,b,255}
end

-- LiteXL theme palette (provided)
local C = {
  background      = hex"#111111",
  text            = hex"#dddddd",
  caret           = hex"#ffffff",
  accent          = hex"#ffb545",
  dim             = hex"#444444",
  divider         = hex"#222222",
  selection       = hex"#000000",
  line_number     = hex"#444444",
  line_number2    = hex"#777777",
  line_highlight  = hex"#222222",
  scrollbar       = hex"#222222",
  scrollbar2      = hex"#444444",
  scrollbar_track = hex"#111111",

  syn_normal      = hex"#dddddd",
  syn_symbol      = hex"#dddddd",
  syn_comment     = hex"#444444",
  syn_keyword     = hex"#777777",
  syn_number      = hex"#72dec2",
  syn_literal     = hex"#72dec2",
  syn_string      = hex"#72dec2",
  syn_operator    = hex"#777777",
  syn_function    = hex"#ffb545",

  guide           = hex"#222222",
  guide_highlight = hex"#777777",
}

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

local function fill_row(x0, y, w, col)
  for x = x0, x0 + w - 1 do
    draw.cell(x, y, col)
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
-- Static-ish content
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
  "  -- policy: only BASE_CODEPOINTS may use italic/bold",
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
  if tok == "" then return C.syn_normal end
  if keywords[tok] then return C.syn_keyword end
  if tok:match("^%-%-") then return C.syn_comment end
  if tok:match("^\"") or tok:match("^'") then return C.syn_string end
  if tok:match("^%d") then return C.syn_number end
  if tok:match("^[%a_][%w_]*%(") then return C.syn_function end
  if tok:match("^[%p]+$") then return C.syn_operator end
  return C.syn_normal
end

local function tokenize(line)
  -- simple tokenizer: split by spaces, keep punctuation attached.
  local out = {}
  for tok in line:gmatch("%S+") do
    out[#out+1] = tok
  end
  return out
end

-- Pre-tokenize to keep perf closer to a real editor (cached syntax pass).
local code_tokens = {}
for i=1,#code_lines do
  code_tokens[i] = tokenize(code_lines[i])
end

local ln_cache = {}
local function line_no_str(n)
  local s = ln_cache[n]
  if s then return s end
  s = string.format("%4d", n)
  ln_cache[n] = s
  return s
end

-- ---------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------

function draw_terminal()
  local cols = TERM_COLS or 0
  local rows = TERM_ROWS or 0
  if cols <= 0 or rows <= 0 then return end

  -- Layout (explicit divider rows/cols to avoid text overwriting separators)
  local top_bar_h    = 2
  local status_bar_h = 1

  if rows < (top_bar_h + status_bar_h + 3) then
    draw.clear(C.background)
    return
  end

  local top_div_y    = top_bar_h
  local bottom_div_y = rows - status_bar_h - 1
  local content_y0   = top_div_y + 1
  local content_y1   = bottom_div_y -- exclusive
  local content_h    = content_y1 - content_y0

  -- Side panels
  local tree_w   = clamp(math.floor(cols * 0.24), 18, 32)
  local minimap_w = clamp(math.floor(cols * 0.05), 6, 10)
  local gutter_w = 6

  local tree_x0   = 0
  local tree_x1   = tree_w            -- exclusive (tree content)
  local tree_div_x = tree_x1          -- divider column

  local doc_x0    = tree_div_x + 1
  local doc_div_x = cols - minimap_w - 1  -- divider column
  if doc_div_x <= doc_x0 + gutter_w + 8 then
    -- If terminal is too narrow, collapse minimap first.
    minimap_w = 0
    doc_div_x = cols - 1
  end

  local mini_x0   = doc_div_x + 1
  local mini_x1   = cols

  local doc_x1    = doc_div_x         -- exclusive (doc content)

  local gutter_div_x = doc_x0 + gutter_w
  if gutter_div_x >= doc_x1 then gutter_div_x = doc_x0 end

  -- Clear once. Everything else is "what you'd actually draw".
  draw.clear(C.background)

  -- -------------------------------------------------------------------
  -- Top bar (row 0..1)
  -- -------------------------------------------------------------------

  -- Title / command hints
  draw_text(2, 0, C.accent, "no-vim", 1)
  draw_text(9, 0, C.dim, "  mock editor perf scene", 0)
  draw_text(cols-22, 0, C.dim, "CTRL+P  Find File", 0)

  -- Tabs line
  local tab = "[main.lua]"
  draw_text(2, 1, C.text, tab, 0)
  draw_text(2 + #tab + 2, 1, C.dim, "[editor.lua] [buffer.lua]", 0)

  -- -------------------------------------------------------------------
  -- Tree panel (content area)
  -- -------------------------------------------------------------------

  local tree_scroll = math.floor((math.sin(t*0.6)*0.5+0.5) * 3)
  local tree_sel = 3
  draw_text(2, content_y0, C.line_number2, "PROJECT", 0, tree_w-3)

  for i=1, #tree_items do
    local y = content_y0 + 2 + (i-1) - tree_scroll
    if y >= content_y0+1 and y < content_y1 then
      if i == tree_sel then
        fill_row(tree_x0, y, tree_w, C.line_highlight)
      end
      local line = tree_items[i]
      local col = (i == tree_sel) and C.accent or C.text
      draw_text(1, y, col, line, 0, tree_w-2)
    end
  end

  -- -------------------------------------------------------------------
  -- Document view (gutter + code)
  -- -------------------------------------------------------------------

  local scroll = math.floor((t*6) % 100000)
  local first_line = scroll
  local cursor_row = math.floor(content_h * 0.45)
  local cursor_line = first_line + cursor_row
  local cursor_col  = 18 + math.floor((math.sin(t*2.0)*0.5+0.5) * 16)

  -- Current line highlight (one row, across doc content only)
  local hl_y = content_y0 + 1 + cursor_row
  if hl_y >= content_y0+1 and hl_y < content_y1 then
    fill_row(doc_x0, hl_y, (doc_x1 - doc_x0), C.line_highlight)
  end

  -- File header
  draw_text(doc_x0+2, content_y0, C.line_number2, "main.lua", 0, (doc_x1 - doc_x0) - 4)

  -- Indent guide columns (relative to code start)
  local code_x0 = gutter_div_x + 1
  local guide_cols = {code_x0 + 2, code_x0 + 6, code_x0 + 10, code_x0 + 14}

  for row=0, content_h-2 do
    local y = content_y0 + 1 + row
    if y >= content_y1 then break end

    local line_no = first_line + row + 1
    local ln = line_no_str(line_no)

    -- Gutter: line numbers + divider
    local ln_col = (line_no == cursor_line) and C.line_number2 or C.line_number
    draw_text(doc_x0, y, ln_col, ln, 0, gutter_w)
    draw.glyph(gutter_div_x, y, C.divider, "│", 0)

    -- Indent guides (subtle)
    for _,gx in ipairs(guide_cols) do
      if gx > gutter_div_x and gx < doc_x1-1 then
        draw.glyph(gx, y, C.guide, "│", 0)
      end
    end

    -- Code tokens (pre-tokenized)
    local toks = code_tokens[(line_no % #code_tokens) + 1]
    local x = code_x0 + 1
    for _,tok in ipairs(toks) do
      local c = color_token(tok)
      local remaining = (doc_x1 - 1) - x
      if remaining <= 0 then break end
      draw_text(x, y, c, tok, 0, remaining)
      x = x + #tok + 1
      if x >= doc_x1-1 then break end
      draw.glyph(x-1, y, C.text, " ", 0)
    end

    -- Inline diagnostics hints (right side, stay off divider)
    if (line_no % 19) == 0 then
      draw_text(doc_x1-18, y, C.accent, "unused var", 0)
    elseif (line_no % 23) == 0 then
      draw_text(doc_x1-20, y, C.accent, "type mismatch", 0)
    end
  end

  -- Selection (single-line region, representative)
  local sel_y = hl_y
  local sel_x0 = code_x0 + 8
  local sel_w  = 14
  if sel_y >= content_y0+1 and sel_y < content_y1 then
    if sel_x0 + sel_w < doc_x1-1 then
      for x = sel_x0, sel_x0 + sel_w - 1 do
        draw.cell(x, sel_y, C.selection)
      end
    end
  end

  -- Caret (blink)
  local blink = (math.floor(t*2) % 2) == 0
  if blink then
    local cx = code_x0 + cursor_col
    local cy = hl_y
    if cy >= content_y0+1 and cy < content_y1-1 and cx > gutter_div_x and cx < doc_x1-1 then
      -- caret block
      draw.glyph(cx, cy, C.caret, "█", 0)
    end
  end

  -- -------------------------------------------------------------------
  -- Minimap (optional)
  -- -------------------------------------------------------------------

  if minimap_w > 0 then
    local blocks = {"░","▒","▓","█"}
    for y = content_y0, content_y1-1 do
      for x = mini_x0, mini_x1-1 do
        local n = hash((x+1)*1315423911 + (y+1)*2654435761 + math.floor(t*10))
        local ch = pick(blocks, n)
        local c1 = ((n % 13) == 0) and C.accent or C.syn_number
        -- request italic: engine policy should force regular for these glyphs
        draw.glyph(x, y, c1, ch, 2)
      end
    end

    -- scrollbar thumb (cell fills, thin)
    local track_x = mini_x1-1
    for y = content_y0, content_y1-1 do
      draw.cell(track_x, y, C.scrollbar_track)
    end
    local thumb_h = clamp(math.floor(content_h * 0.25), 3, content_h)
    local thumb_y = content_y0 + math.floor((math.sin(t*0.7)*0.5+0.5) * (content_h - thumb_h))
    for y = thumb_y, thumb_y + thumb_h - 1 do
      draw.cell(track_x, y, C.scrollbar2)
    end
  end

  -- -------------------------------------------------------------------
  -- Status bar (last row, separate from divider row)
  -- -------------------------------------------------------------------

  local status_y = rows - 1
  local mode = "NORMAL"
  local pos  = string.format("Ln %d, Col %d", cursor_line, cursor_col)
  draw_text(2, status_y, C.accent, "no-vim", 1)
  draw_text(10, status_y, C.dim, mode, 0)
  draw_text(cols-#pos-2, status_y, C.text, pos, 0)

  -- -------------------------------------------------------------------
  -- Dividers LAST (so nothing overwrites box-drawing chars)
  -- -------------------------------------------------------------------

  hline(0, top_div_y, cols, C.divider, "─")
  hline(0, bottom_div_y, cols, C.divider, "─")

  vline(tree_div_x, content_y0, content_h, C.divider, "│")
  vline(doc_div_x,  content_y0, content_h, C.divider, "│")
end
