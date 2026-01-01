# monotome.window
The windowing API for Monotome, handling the main display context, sizing, and positioning.

### Index
* [`init`](#monotomewindowinit)
* [`width`](#monotomewindowwidth)
* [`height`](#monotomewindowheight)
* [`columns`](#monotomewindowcolumns)
* [`rows`](#monotomewindowrows)
* [`pos_x`](#monotomewindowpos_x)
* [`pos_y`](#monotomewindowpos_y)
* [`set_title`](#monotomewindowset_title)
* [`set_size`](#monotomewindowset_size)
* [`set_position`](#monotomewindowset_position)
* [`maximize`](#monotomewindowmaximize)
* [`minimize`](#monotomewindowminimize)

---

## monotome.window.init
Initializes the main window and renderer context.

### Usage
```lua
monotome.window.init(width, height, title, flags?)
```

### Arguments
- `number: width` - Window width in pixels.
- `number: height` - Window height in pixels.
- `string: title` - Window header title.
- `table: flags` - Optional list of config strings (`"resizable"`, `"fullscreen"`, `"borderless"`).

### Returns
None.

---

## monotome.window.width
Gets the current window width in pixels.

### Usage
```lua
width = monotome.window.width()
```

### Arguments
None.

### Returns
- `number: width` - The width of the window in pixels.

---

## monotome.window.height
Gets the current window height in pixels.

### Usage
```lua
height = monotome.window.height()
```

### Arguments
None.

### Returns
- `number: height` - The height of the window in pixels.

---

## monotome.window.columns
Gets the window width in calculated text columns.

### Usage
```lua
cols = monotome.window.columns()
```

### Arguments
None.

### Returns
- `number: cols` - The number of text columns that fit in the window.

---

## monotome.window.rows
Gets the window height in calculated text rows.

### Usage
```lua
rows = monotome.window.rows()
```

### Arguments
None.

### Returns
- `number: rows` - The number of text rows that fit in the window.

---

## monotome.window.pos_x
Gets the window's X position on the desktop.

### Usage
```lua
x = monotome.window.pos_x()
```

### Arguments
None.

### Returns
- `number: x` - The X coordinate of the window's top-left corner.

---

## monotome.window.pos_y
Gets the window's Y position on the desktop.

### Usage
```lua
y = monotome.window.pos_y()
```

### Arguments
None.

### Returns
- `number: y` - The Y coordinate of the window's top-left corner.

---

## monotome.window.set_title
Updates the window header title.

### Usage
```lua
monotome.window.set_title(title)
```

### Arguments
- `string: title` - The new window title.

### Returns
None.

---

## monotome.window.set_size
Sets the window dimensions in pixels.

### Usage
```lua
monotome.window.set_size(width, height)
```

### Arguments
- `number: width` - New width in pixels.
- `number: height` - New height in pixels.

### Returns
None.

---

## monotome.window.set_position
Sets the window position on the desktop.

### Usage
```lua
monotome.window.set_position(x, y)
```

### Arguments
- `number: x` - New X coordinate.
- `number: y` - New Y coordinate.

### Returns
None.

---

## monotome.window.maximize
Maximizes the window to fill the screen.

### Usage
```lua
monotome.window.maximize()
```

### Arguments
None.

### Returns
None.

---

## monotome.window.minimize
Minimizes the window to the taskbar/dock.

### Usage
```lua
monotome.window.minimize()
```

### Arguments
None.

### Returns
None.
