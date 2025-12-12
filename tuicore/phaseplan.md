Alright, let’s turn the mess in both our heads into a clean roadmap.

I’ll treat what you *already* have as **Phase 0**, then stack everything on top in small, testable layers.



## Phase 0 — Host skeleton locked (what you have now)

**Goal:**
Native host owns loop, Lua owns behaviour. No rendering API yet.

**Status (done):**

* SDL2 window (fixed size for now).
* SDL event pump (QUIT closes).
* High-res dt via performance counter.
* LuaJIT state:

  * load `main.lua` next to exe,
  * call `init_terminal()`,
  * per-frame: `update_terminal(dt)`, `draw_terminal()`.
* `call_lua` helpers (noargs / number), centralised error handling.

> This is your “Qterm exists” baseline. Good.



## Phase 1 — Grid + window semantics (no fonts yet)

**Goal:**
Lock in how the “grid in the window” works before text exists.

**Decisions:**

* **Fit mode is default**:

  * Window: any size.
  * Cell size: **temporary fixed ints** (e.g. `cell_w = 16`, `cell_h = 32`) until fonts.
  * Grid:

    ```text
    cols = floor(window_w / cell_w)
    rows = floor(window_h / cell_h)
    origin_x = 0
    origin_y = 0
    used_w = cols * cell_w
    used_h = rows * cell_h
    ```
  * Letterbox: right + bottom only, filled by `draw.clear`.

**Host work (Odin):**

* Add a tiny “render state” chunk:

  * `cell_w`, `cell_h`
  * `cols`, `rows`
  * `origin_x`, `origin_y`

* Recompute it whenever:

  * window is created,
  * window resized (handle SDL_WINDOWEVENT_RESIZED later).

* Add host-side helpers (no Lua yet):

  * grid → pixel:

    * `grid_to_pixel(x, y) -> (px, py)` = `origin + cell * size`
  * bounds check:

    * `inside_grid(x, y)`.

**Lua surface (still no `draw` module):**

* `draw_terminal()` for now might just `print` grid size via `system` later; or stay empty.

**Tests:**

* Log `cols`, `rows` when you resize the window.
* Confirm top-left is (0,0), new cols/rows appear on right/bottom.



## Phase 2 — `draw` module v0: clear + cells (no glyphs)

**Goal:**
Give Lua a **minimal, immediate-mode** drawing API in cell-space.

**Lua API (engine-owned module `"draw"`)**

* `draw.clear(color)`
* `draw.cell(x, y, color)`

Where:

* `color` is a `{ r, g, b, a }` table (Lua-side convention).
* `x, y` are integers in grid-space.

**Semantics:**

* `draw.clear(color)`:

  * Converts color to RGBA.
  * Sets SDL render draw color.
  * Calls `SDL_RenderClear`.
  * Clears **whole window** (including letterbox).

* `draw.cell(x, y, color)`:

  * If `(x,y)` outside grid → no-op.
  * Use `grid_to_pixel` to get `(px, py)`.
  * Fill rect `(px, py, cell_w, cell_h)` with that color.

**Host work:**

* Build `draw` Lua module table in Odin:

  * C-functions: `L_draw_clear`, `L_draw_cell`.
  * Register them in `package.loaded["draw"]`.

* In `draw_terminal`, Lua can now:

  ```lua
  local draw = require "draw"
  function draw_terminal()
    draw.clear({r=0,g=0,b=0,a=255})
    draw.cell(0, 0, {r=255,g=0,b=0,a=255})
  end
  ```

**Tests:**

* Move a colored cell across the grid based on `t` from `update_terminal`.
* Resize window: confirm cells stay crisp & aligned, grid grows/shrinks as expected.

At this point you have a **pure cell-based TUI canvas**.



## Phase 3 — SDL_ttf integration + cell size from font

**Goal:**
Swap “fake cell size” for **real metrics from a monospace TTF**. Still no glyph drawing; just using font metrics to drive the grid.

**Host work:**

* Use `vendor:sdl2/ttf`:

  * `sdl2_ttf.Init()` / `Quit()`.
  * `OpenFont(font_path, ptsize)` once at startup.

* Font metrics:

  * `cell_h = FontHeight(font)` or `FontLineSkip(font)`.
  * `cell_w` = glyph advance for a representative glyph (`GlyphMetrics(font, 'M', ...)`).
  * Optionally assert `FontFaceIsFixedWidth(font)`.

* Replace the temporary `cell_w/cell_h` with these metrics.

* Let the grid recompute with new cell size.

**Lua:**

* No API change; `draw.clear` and `draw.cell` just use the new cell metrics.
* TUI apps now get more/fewer cells based on font size & window size.

**Tests:**

* Hardcode a font size (e.g. 16).
* Confirm grid behaves sensibly, and changing that size in host changes `cols/rows`.



## Phase 4 — `draw.glyph` and basic text (atlas or simple path)

**Goal:**
Add text drawing in a way that doesn’t lock you into a stupid slow design.

**Lua API extension:**

* `draw.glyph(x, y, ch, color)`

  * `ch` = 1-char Lua string (for v0).
  * `x, y` = grid coords.
  * `color` = fg color object.

(You can later build `draw.text(x, y, string, color)` in Lua.)

**Host text strategy (v0):**

You have two options here, pick one:

### 4A. MVP (naive) — okay for light use

* Use SDL_ttf `RenderUTF8_Blended` per `draw.glyph`.
* Convert surface → texture → render into the cell rect → free surface/texture.
* Only acceptable if:

  * you use it for debug/status text,
  * you know you’ll replace it before doing full-screen text.

### 4B. Proper path — static ASCII atlas

* On startup:

  * For ASCII 32–126:

    * Render each glyph once via SDL_ttf to a temporary surface.
    * Pack into an SDL texture atlas (grid or simple row/column).
    * Store UVs (source rect) and baseline offsets.

* At draw time:

  * `draw.glyph` → look up UVs, draw textured quad in the cell rect.

I’d strongly recommend **4B** as the first “real text” implementation. Once that works, you can extend “what’s in the atlas”.

**Tests:**

* Render a line of ASCII text across the grid.
* Verify alignment with cells; no overlaps, no jitter with resize.



## Phase 5 — UTF-8 / Nerd Font support (better atlas)

**Goal:**
Make glyphs beyond ASCII not totally dumb.

**Host work:**

* Extend the atlas:

  * Add a small set of NF/Unicode glyphs you care about to the pre-bake list.
  * Add a map: `codepoint → glyph_info{ atlas_rect, advance }`.

* (Optional but ideal) On-demand caching:

  * When `draw.glyph` sees a codepoint not in the map:

    * Render that glyph via SDL_ttf.
    * Place it in the atlas (next free slot).
    * Record its UVs.

* If the atlas fills:

  * For now: stop caching and draw a fallback glyph (`?`).
  * Later: add multiple atlas pages.

**Lua:**

* No API change: `draw.glyph` just “suddenly” supports more characters.



## Phase 6 — Font-size changes (Ctrl+Scroll semantics)

**Goal:**
Runtime TTF resizing like LiteXL / terminals.

**Host work:**

* Track `current_font_size`.
* Expose a **host-level** way to change it (for now, maybe a keybind hardcoded).

On font size change:

1. Close old font, open new one with new size.
2. Recompute `cell_w`, `cell_h`.
3. Recompute grid (`cols`, `rows`) based on window.
4. Clear and rebuild the glyph atlas (ASCII+NF subset).
5. Redraw.

Lua doesn’t know “font size changed”; it just sees a different grid size and bigger glyphs.

Later you can expose:

* `system.set_font_size(size)` if you want Lua-controlled zoom, but that’s optional.



## Phase 7 — Optional fixed-grid mode (retro / 80×25)

**Goal:**
Add TMGUI-style “virtual grid” as an **alternative**, not the default.

**Host work:**

* Add a config flag:

  * `mode = "fit"` (default) OR
  * `mode = "fixed"` with `target_cols`, `target_rows`.

* In fixed mode:

  * Use TMGUI-style math:

    * `virtual_w = target_cols * cell_w`
    * `virtual_h = target_rows * cell_h`
    * `scale = floor(min(window_w/virtual_w, window_h/virtual_h))`
    * `used_w = virtual_w * scale`, etc.
  * Use `scale` in your grid→pixel transform.

**Lua:**

* Still just sees `(cols, rows)`.
  In fixed mode, `cols/rows` are the *virtual* values you configured.



## Phase 8 — System module, resize / grid introspection

**Goal:**
Let Lua react to grid size, but keep window policy in host.

**Lua API (`system`):**

* `system.get_grid_size()` → `{cols, rows}`
* `system.get_window_size()` → `{w, h}` in pixels
* `system.get_font_size()` → maybe

Later, if you *really* want:

* `system.set_title("…")`
* `system.set_window_size(w, h)`
* `system.set_mode("fit"|"fixed")`

But don’t add those until you have an actual use.



### TL;DR phase stack

* **0** – Host loop + Lua callbacks (done).
* **1** – Grid + window math (fake cell size).
* **2** – `draw` v0: `clear` + `cell` (no text).
* **3** – Plug SDL_ttf in, derive cell size from font.
* **4** – `draw.glyph` via atlas (ASCII first).
* **5** – Extend atlas for UTF-8 / Nerd Font (on-demand caching).
* **6** – Runtime font-size changes → rebuild atlas + recompute grid.
* **7** – Optional fixed-grid mode, TMGUI-style scaling.
* **8** – `system` surface for grid/window introspection (and maybe font size later).

If you want, next step we can zoom into **Phase 1+2 only** and spec exactly what host state and Lua surface you’ll add *right now* to get `draw.clear` + `draw.cell` working with fake `cell_w/cell_h`.

