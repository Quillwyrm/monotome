local monotome = require("monotome")

local draw     = monotome.draw
local window   = monotome.window
local input    = monotome.input
local font     = monotome.font
local runtime  = monotome.runtime


local C = {
	bg = { 15, 12, 21, 255 },
	panel = { 16, 22, 30, 255 },
	border = { 99, 123, 146, 255 },
	text = { 210, 214, 210, 255 },
	muted = { 140, 150, 165, 255 },
	accent = { 24, 110, 116, 255 },
	ok = { 70, 220, 150, 255 },
	warn = { 191, 132, 98, 255 },
	hot = { 255, 120, 200, 255 },

	-- cursor overlay (cell-space)
	cursor_fill = { 255, 255, 255, 36 },
	cursor_line = { 255, 255, 255, 12 },
	cursor_tip_bg = { 16, 22, 30, 220 },
}

local S = {
	t = 0,
	font_pt = 18,
	ax = 15,
	ay = 12,
	typed = "",
	pulses = {},
	undec = false,
	test_face = 1,

	show_cursor = true,
}

local function btn(x, y, label, active)
	local w = #label + 2
	local mx, my = input.mouse_pos()
	local hot = (mx >= x and mx < x + w and my == y)
	local bg_col = active and C.accent or (hot and C.border or C.panel)
	local fg_col = hot and C.bg or (active and C.text or C.muted)
	draw.rect(x, y, w, 1, bg_col)
	draw.text(x + 1, y, label, fg_col)
	return hot and input.mouse_pressed("left")
end

local function header(x, y, w, title)
	draw.rect(x, y, w, 1, C.accent)
	draw.text(x + 1, y, title:upper(), C.bg, 1) -- face=2 (Bold)
end

local function panel_frame(x, y, w, h)
	draw.rect(x, y, w, h, C.panel)
	draw.text(x, y, "┌" .. ("─"):rep(w - 2) .. "┐", C.border)
	draw.text(x, y + h - 1, "└" .. ("─"):rep(w - 2) .. "┘", C.border)
	for i = 1, h - 2 do
		draw.text(x, y + i, "│", C.border)
		draw.text(x + w - 1, y + i, "│", C.border)
	end
end

-- Fix: Added namespace prefixes to state keys to prevent name collisions
local function input_monitor(x, y, label, key, is_mouse)
	local down = is_mouse and input.mouse_down(key) or input.key_down(key)
	local p = is_mouse and input.mouse_pressed(key) or input.key_pressed(key)
	local r = is_mouse and input.mouse_released(key) or input.key_released(key)

	local state_id = (is_mouse and "m:" or "k:") .. key
	if p then S.pulses[state_id .. "_p"] = 0.2 end
	if r then S.pulses[state_id .. "_r"] = 0.2 end

	draw.text(x, y, string.format("%-4s", label), C.muted)
	draw.text(x + 5, y, down and "●" or "·", down and C.ok or C.border)
	if (S.pulses[state_id .. "_p"] or 0) > 0 then draw.text(x + 7, y, "P", C.ok) end
	if (S.pulses[state_id .. "_r"] or 0) > 0 then draw.text(x + 9, y, "R", C.ok) end
end

local function clampi(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

local function cursor_overlay(cols, rows, world_x0, world_w)
	if not S.show_cursor then return end

	local cx, cy = input.mouse_pos()

	-- Only show overlay when cursor is inside the world panel.
	if cx < world_x0 or cx >= (world_x0 + world_w) or cy < 0 or cy >= rows then
		return
	end

	-- crosshair
	draw.rect(world_x0, cy, world_w, 1, C.cursor_line)
	draw.rect(cx, 0, 1, rows, C.cursor_line)

	-- hovered cell highlight
	draw.rect(cx, cy, 1, 1, C.cursor_fill)

	-- tooltip (cell coords + world-local coords)
	local wx = cx - world_x0
	local wy = cy

	local tip = string.format("%d,%d  (w:%d,%d)", cx, cy, wx, wy)
	local tw = #tip + 2

	local tx = cx + 1
	local ty = cy - 1
	if tx + tw >= cols then tx = cx - tw end
	if ty < 0 then ty = cy + 1 end

	tx = clampi(tx, world_x0, (world_x0 + world_w) - tw)
	ty = clampi(ty, 0, rows - 1)

	draw.rect(tx, ty, tw, 1, C.cursor_tip_bg)
	draw.text(tx + 1, ty, tip, C.text)
end
----------------------------------------
-- INIT
----------------------------------------
function runtime.init()
	window.init(1200, 900, "monotome testbed", { "vsync_on", "resizable" })
	font.init(S.font_pt)
end

----------------------------------------
-- UPDATE
----------------------------------------
function runtime.update(dt)
	S.t = S.t + dt
	for k, v in pairs(S.pulses) do
		S.pulses[k] = v - dt
		if S.pulses[k] <= 0 then S.pulses[k] = nil end
	end

	local txt = input.get_text()
	if txt ~= "" then S.typed = (S.typed .. txt) end
	if input.key_pressed("backspace") or input.key_repeat("backspace") then S.typed = S.typed:sub(1, -2) end

	local ctrl = input.key_down("lctrl") or input.key_down("rctrl")
	if ctrl and input.key_pressed("v") then S.typed = S.typed .. (window.get_clipboard() or "") end
	if ctrl and input.key_pressed("c") then window.set_clipboard(S.typed) end

	local speed = input.key_down("lshift") and 2 or 1
	if input.key_down("w") then S.ay = S.ay - speed end
	if input.key_down("s") then S.ay = S.ay + speed end
	if input.key_down("a") then S.ax = S.ax - speed end
	if input.key_down("d") then S.ax = S.ax + speed end

	-- small toggle polish: show/hide cursor overlay
	if input.key_pressed("tab") then S.show_cursor = not S.show_cursor end
end

----------------------------------------
-- DRAW
----------------------------------------
function runtime.draw()
	local cols, rows = window.grid_size()
	local m = window.metrics()
	local win_x, win_y = window.position() -- POS should always reflect the live window position

	draw.clear(C.bg)

	panel_frame(0, 0, 36, rows)
	header(1, 1, 34, "System")

	local cur_y = 3
	draw.text(2, cur_y, "FONT:", C.muted)
	if btn(8, cur_y, " - ") then
		S.font_pt = math.max(8, S.font_pt - 1); font.set_size(S.font_pt)
	end
	if btn(13, cur_y, " + ") then
		S.font_pt = S.font_pt + 1; font.set_size(S.font_pt)
	end
	draw.text(18, cur_y, tostring(S.font_pt) .. "px", C.text); cur_y = cur_y + 2

	if btn(2, cur_y, " DECOR ", not S.undec) then
		S.undec = not S.undec; window.set_undecorated(S.undec)
	end
	if btn(11, cur_y, " MIN ") then window.minimize() end
	if btn(18, cur_y, " MAX ") then window.maximize() end; cur_y = cur_y + 2

	header(1, cur_y, 34, "Metrics")
	cur_y = cur_y + 2
	draw.text(2, cur_y, string.format("GRID: %dx%d", m.cols, m.rows), C.muted)
	draw.text(18, cur_y, string.format("CELL: %dx%d", m.cell_w, m.cell_h), C.muted); cur_y = cur_y + 1
	draw.text(2, cur_y, string.format("WND:  %dx%d", m.px_w, m.px_h), C.muted)
	draw.text(18, cur_y, string.format("WIN:  %d,%d", win_x, win_y), C.muted); cur_y = cur_y + 1

	-- live, obvious coords
	local mx, my = input.mouse_pos()
	draw.text(2, cur_y, string.format("AT:   %d,%d", S.ax, S.ay), C.muted)
	draw.text(18, cur_y, string.format("MOUSE:%d,%d", mx, my), C.muted); cur_y = cur_y + 2

	header(1, cur_y, 34, "Input Monitor")
	cur_y = cur_y + 2
	local keys = { { "W", "w" }, { "A", "a" }, { "S", "s" }, { "D", "d" }, { "SPC", "space" }, { "ENT", "enter" }, { "BS", "backspace" }, { "ESC", "esc" } }
	for i, k in ipairs(keys) do
		local r_idx = math.floor((i - 1) / 2)
		local c_idx = (i - 1) % 2
		input_monitor(2 + (c_idx * 16), cur_y + r_idx, k[1], k[2])
	end
	cur_y = cur_y + 5
	input_monitor(2, cur_y, "M1", "left", true)
	input_monitor(18, cur_y, "M2", "right", true); cur_y = cur_y + 2

	header(1, cur_y, 34, "Glyph Lab")
	cur_y = cur_y + 2
	local faces = { "REG", "BOLD", "ITAL", "BI" }
	for i, name in ipairs(faces) do
		if btn(2 + ((i - 1) * 8), cur_y, name, S.test_face == i) then S.test_face = i end
	end
	cur_y = cur_y + 2
	draw.text(2, cur_y, "ABC abc 123 !@# Ω≈ç√ ∫µ≤≥", C.text, S.test_face)
	cur_y = cur_y + 2

	header(1, cur_y, 34, "Clipboard")
	cur_y = cur_y + 2
	local box_w, box_h = 32, 4

	draw.rect(2, cur_y, box_w, box_h, C.bg)
	draw.text(2, cur_y - 1, "TEXT BUFFER", C.border)

	for i = 0, box_h - 1 do
		local start_idx = (i * box_w) + 1
		local line = S.typed:sub(start_idx, start_idx + box_w - 1)
		if #line > 0 then draw.text(2, cur_y + i, line, C.warn) end
	end

	cur_y = cur_y + box_h + 1
	if btn(2, cur_y, " COPY ") then window.set_clipboard(S.typed) end
	if btn(10, cur_y, " PASTE ") then S.typed = S.typed .. (window.get_clipboard() or "") end
	if btn(19, cur_y, " CLEAR ") then S.typed = "" end

	local world_x0 = 37
	local pw = cols - 37
	panel_frame(world_x0, 0, pw, rows)
	header(world_x0 + 1, 1, pw - 2, "World View")

	-- world contents
	draw.text(world_x0 + S.ax, S.ay, "@", C.hot)

	-- cursor overlay drawn last (on top)
	cursor_overlay(cols, rows, world_x0, pw)
end

