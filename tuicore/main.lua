local t = 0

function init_terminal()
  -- nothing yet
end

function update_terminal(dt)
  t = t + dt
end

function draw_terminal()
  draw.clear({0,0,0,255})

  local cols = TERM_COLS or 0
  local rows = TERM_ROWS or 0
  if cols <= 0 or rows <= 0 then return end

  -- border
  for x = 0, cols-1 do
    draw.cell(x, 0,        {0,180,255,255})
    draw.cell(x, rows-1,   {0,180,255,255})
  end
  for y = 0, rows-1 do
    draw.cell(0,      y,   {0,180,255,255})
    draw.cell(cols-1, y,   {0,180,255,255})
  end

  -- moving block
  local x = math.floor((t * 10) % cols)
  local y = math.floor(rows / 2)
  draw.cell(x, y, {255, 80, 80, 255})
end

