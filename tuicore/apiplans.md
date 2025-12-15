Here’s the minimal API I’d infer from everything we’ve been circling, split into the buckets we agreed on. This is “Stage 0: Lua-scriptable cell TUI platform”, not “editor features”.

## Core invariants

* **All `draw.*` coordinates and sizes are in *cell units***. Always.
* Colors are `{r,g,b,a}` with numeric entries. **No clamping**.
* `face` is **0..3**.
* **Policy:** if a glyph’s codepoint is not in `BASE_CODEPOINTS`, the engine forces `face = 0` for that glyph (coverage UX).

## Callbacks

* `tuicore.load()`
* `tuicore.update(dt)`  (`dt` seconds, last-frame delta)
* `tuicore.draw()`

## `window.*`

Minimum to boot and query the surface.

* `window.init(w, h, title, opts?)`

  * `opts` (optional table): `{ resizable = bool, ... }` (only the flags you actually support now)
* `window.size() -> w, h` (pixels)

Optional-but-still-minimal:

* `window.set_title(title)`
* `window.set_size(w, h)` (pixels)

## `system.*`

Keep this tiny; you already pass `dt` into `update(dt)`.

* `system.time() -> seconds` (monotonic-ish, whatever you’re using internally)
* `system.fps() -> number` (optional convenience; not required)

(You can skip `system.dt()` because `dt` comes via callback. Add it only if you feel real friction.)

## `draw.*`

Keep the existing 3 + your 2 new ones.

* `draw.clear(rgba)`
* `draw.cell(x, y, rgba)` (fills one cell)
* `draw.rect(x, y, w, h, rgba)` (fills a cell-rect)
* `draw.glyph(x, y, rgba, text, face)` (first codepoint only, one cell; crop-to-cell; █ special-case)
* `draw.text(x, y, rgba, text, face[, max_cols])`

  * single line (stop at `\n`)
  * advances exactly 1 cell per codepoint
  * applies the same crop + per-codepoint face fallback as `draw.glyph`
  * optional `max_cols` is **clip width**, not wrapping

That’s enough to build essentially any TUI entirely in Lua, while keeping the host side small and stable.
-
