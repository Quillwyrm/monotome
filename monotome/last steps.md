### Calls to add

#### Window getters (multi-return)

* `window.size() -> (w, h)`
* `window.grid_size() -> (cols, rows)`
* `window.position() -> (x, y)`
* `window.cell_size() -> (cell_w, cell_h)`
* `window.metrics() -> (cols, rows, cell_w, cell_h, w, h, x, y)`

#### Window lifecycle

* `window.close()` *(request quit; don’t destroy immediately)*
* `window.should_close() -> bool`
* `window.restore()`

#### Window controls / QoL

* `window.set_min_size(w, h)`
* `window.set_max_size(w, h)`
* `window.set_vsync(on)`
* `window.set_resizable(on)`
* `window.set_fullscreen(on)`
* `window.set_bordered(on)`
* `window.set_cursor(name)`
* `window.cursor_show()`
* `window.cursor_hide()`
* `window.cursor_visible() -> bool` *(optional)*

#### Input

* `input.mouse_delta() -> (dx, dy)` *(cell units)*

#### Clipboard

* `window.get_clipboard() -> string`
* `window.set_clipboard(text)`

Here’s a clean “easy wins first” phase plan, grouped by **shared plumbing** so you don’t touch the same code repeatedly.

## Phase 1 — Pure getters (no SDL calls, mostly returning existing state)

**Easiest, almost risk-free**

* `window.size() -> (w, h)` *(wraps existing width/height)*
* `window.grid_size() -> (cols, rows)` *(wraps existing columns/rows)*
* `window.position() -> (x, y)` *(wraps existing pos_x/pos_y)*
* `window.cell_size() -> (cell_w, cell_h)` *(existing globals)*
* `window.metrics() -> (...)` *(just bundles the above)*

**Bonus in same pass:** delete the single-value getters once Lua is updated.

## Phase 2 — Quit/close semantics (tiny state + one flag)

**Small but important**

* `window.close()` *(sets `quit_requested = true`)*
* `window.should_close() -> bool` *(returns `quit_requested`)*
* Host loop sets `quit_requested = true` on `.QUIT` / close-request events

This is all internal state; no window destruction from Lua.

## Phase 3 — Constraints + toggles (direct SDL calls, straightforward)

**Still easy, just binding calls**

* `window.set_min_size(w, h)`
* `window.set_max_size(w, h)`
* `window.set_resizable(on)`
* `window.set_vsync(on)`
* `window.set_fullscreen(on)`
* `window.set_bordered(on)`
* `window.restore()` *(paired with your existing minimize/maximize)*

## Phase 4 — Cursor (a bit more stateful, but contained)

**One small internal cache of system cursors**

* `window.set_cursor(name)`
* `window.cursor_show()`
* `window.cursor_hide()`
* `window.cursor_visible() -> bool` *(optional)*

## Phase 5 — Input sugar (no new SDL work, just tracking)

**Easy, but touches input module**

* `input.mouse_delta() -> (dx, dy)` *(cell delta from last frame)*

## Phase 6 — Clipboard (simple, but has “free memory correctly” footgun)

**Easy API, but do it carefully**

* `window.get_clipboard() -> string` *(must free SDL buffer via `SDL_free`)*
* `window.set_clipboard(text)`

---

If you want max momentum: do **Phase 1 + Phase 2** in one sitting (pure API ergonomics + quit semantics), then **Phase 3** next (all the SDL toggles are basically one-liners).

