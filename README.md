![runeslate](logo.png)
# RuneSlate

RuneSlate is a **Lua-scriptable textmode rendering engine** written in **Odin**, built on **raylib**.

**Write Lua, draw glyphs, ship little tools.**

It’s aimed at **terminal-style apps**, **experiments**, **toys**, and **small games** that want a textmode look, expressive scripting, and fast iteration.

## What you get

A small set of primitives exposed to Lua:

* `window` — create/configure the window, query metrics, clipboard, cursor, close state
* `draw` — clear, fill cells/rects, draw glyphs/text
* `input` — keyboard/mouse polling + text input
* `font` — load TTF/OTF faces and control sizing (regular/bold/italic/bold-italic)

## Notes

* Text rendering is **TTF/OTF-based** (not a bitmap font sheet).
* Rendering is **cell-space / textmode**: you work in `(x, y)` cells.
* RuneSlate is **not a terminal emulator**.

## Status

Early development / polishing. The core is usable, but the API may change as the project settles.

## Run it

```sh
odin run .
```

