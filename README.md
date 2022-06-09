# keymap-layer.nvim

**In this branch, unlike master, Layer class remap global key mappings, instead of buffer local.**

**This library was created as a backend for [pink hydra](https://github.com/anuvyklack/hydra.nvim),
and in most cases you want use it.**

**Keymap-layer.nvim** is a small library which allows to temporarily remap some keys while
all others will be working as usual — to create a layer above your keybindings which will
overlap some of them.
On exiting layer the original keybindings become available again like nothing have happened.

```
                          --------------------------
                         /  q  /     /     /  r  /
                        /-----/-----/-----/-----/-
                       /     /  s  /     /     /   <--- Layer overlap some keys
                      /-----/-----/-----/-----/--
                     /     /     /     /  v  /|
                    /-----/-----/-----/-----/--
                            |   |         |   |
                          --|---|---------|---|-----
                         /  !  /| w  /  e |/  !  /
                        /-----/-|---/-----|-----/--
                       /  a  /  !  /  d  /| f  /    <--- Original keybindings
                      /-----/-----/-----/-|---/--
                     /  z  /  x  /  c  /  !  /
                    /-----/-----/-----/-----/--
```

## Creating a layer

A simple example for illustration of what is written below:

```lua
local KeyLayer = require('keymap-layer')

local m = {'n', 'x'} -- modes
local side_scroll = KeyLayer({
    enter = {
       {m, 'zl', 'zl'},
       {m, 'zh', 'zh'},
    },
    layer = {
       {m, 'l', 'zl'},
       {m, 'h', 'zh'},
    },
    exit = {
       {m, 'q'}
    },
    config = {
       on_enter = function() print("Enter layer") end,
       on_exit  = function() print("Exit layer") end,
       timeout = 3000, -- milliseconds
    }
})
```

---

To creat a new Layer object, you need to call constructor with input table with 4 next
fields:

```lua
local KeyLayer = require('keymap-layer')

local layer = KeyLayer({
   enter = {...},
   layer = {...},
   exit = {...}
   config = {...},
})
```

`enter`, `layer` and `exit` tables containes the keys to remap.
They all accept a list of keymappings, each of the form:
```lua
{mode, lhs, rhs, opts}
```
which is absolutely identical to `vim.keymap.set()` signature.

`enter` and `exit` tables are optional, `layer` table is mandatory.

Key mappings in `enter` table are activate layer. Key mappings in `layer` and `exit`
tables become available only when layer is active. And mappings in `exit` table deactivate
layer.

If no one `exit` key was passed (`exit` table is empty), the `<Esc>` will be bind by default.

The `rhs` of the mapping can be `nil`.
For `enter` and `exit` tables it means just to enter/exit the layer and doesn't do any
side job.  For `layer` table, it means to disable this key while layer is active
(internally it will be mapped to `<Nop>`).

For example, to disable the input mode inside the layer, you can use the next snippet:
```lua
local m = {'n', 'x'}

KeyLayer {
   enter = {...},
   layer = {
       {m, 'i'},   {m, 'a'},   {m, 'o'},   {m, 's'},   {m, 'c'},
       {m, 'I'},   {m, 'A'},   {m, 'O'},   {m, 'S'},   {m, 'cc'},
       {m, 'gi'},                                      {m, 'C'}
       {m, '#I'},
       ...
   },
   exit = {...}
}
```

**Note:** Only one Layer can be active at a time. The next one will stop the previous.

### `config` table

#### `on_enter` and `on_exit`
`function`

Functions that will be executed on entering and before exiting the layer.

#### `timeout`
`boolean | number` (default: `false`)

The `timeout` option starts a timer for the corresponding amount of seconds milliseconds
that disables the layer.  Calling any layer key will refresh the timer.
If set to `true`, the timer will be set to `timeoutlen` option value (see `:help timeoutlen`).

## Global variable

The active layer set `_G.active_keymap_layer` global variable, which contains the
reference to the active layer object. If no active layer, it is `nil`.
With it one layer checks if there is any other
active layer.  It can also be used for statusline notification, or anything else.

## Layer object

Beside constructor, Layer object has next public methods:

- `layer:enter()` : activate layer;
- `layer:exit()` : deactivate layer.

<!-- vim: set tw=90: -->
