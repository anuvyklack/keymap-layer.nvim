# keymap-layer.nvim

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

### `enter`, `layer` and `exit` tables

`enter`, `layer` and `exit` tables containes the keys to remap.
They all accept a list of keymappings, each of the form:
```lua
{mode, lhs, rhs, opts}
```
which is pretty-much compares to the signature of the `vim.keymap.set()` function with
some modifications.  `layer` table is mandatory, `enter` and `exit` tables are optional.
Key mappings in `enter` table are activate layer. Key mappings in `layer` and `exit`
tables become available only when layer is active. Mappings in `exit` table deactivate
layer.  If no one `exit` key was passed (`exit` table is empty), the `<Esc>` will be bind
by default.

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
       {m, 'i'},   {m, 'a'},   {m, 'o'},   {m, 's'},   {m, 'c', '<Nop>', {nowait = true}},
       {m, 'I'},   {m, 'A'},   {m, 'O'},   {m, 'S'},   {m, 'cc'},
       {m, 'gi'},                                      {m, 'C'},
       {m, '#I'},
       ...
   },
   exit = {...}
}
```

**Note:** Only one Layer can be active at a time. The next one will stop the previous.

#### `opts`

`opts` table of each keymap accepts (in theory) all key that `vim.keymap.set` `opts`
accepts. But their interaction has not been properly tested.

In reality, key `buffer` will have no effect, since Layer binds its keymaps as buffer
local and will overwrite this flag. This in terms make flag `nowait` awailable, and
allows, for example bind exit key:
```lua
{'n', 'q', <Nop>, {nowait = true}}
```
which will exit layer, without waiting `timeoutlen` milliseconds for possible continuation.

Keymaps in `exit` table accepts an extra key in `opts` table:

##### `after_exit` 
`boolean`

```lua
exit = {
    { 'n', '<Enter>', '<cmd>Neogit<CR>', { after_exit = true } }
    ...
}
```

By default, when you press the exit key, Layer executes in the following order:

1. `rhs` of the keymap;
2. `config.on_exit()` function (passed in `config` table, see below);
3. restore original keymaps.

This option allows to change this order the next way:

1. `config.on_exit()` function (passed in `config` table, see below);
2. restore original keymaps;
3. `rhs` of the keymap.

This is always need when `rhs` opens new buffer with custom buffer local keymaps.  For
example, **Neogit**.  Without this flag **Neogit** opens its buffer in the Layer scope,
and then happens two competing processes in undefined order: Layer tries to save the
original keymaps and set its one, and Neogit tries to set its own keymaps.
Then if Layer managed first, on exiting, it will restore keymaps saved before Neogit
set its own, and Neogit keymaps will be lost: you will get Neogit buffer without Neogit
keybindings.
Exactly for this case, this option was added: you first exit the Layer and then open
Neogit, and they don't interfere each other.

### `config` table

#### `on_enter` and `on_exit`
`function`

Functions that will be executed on entering and on exiting the layer.

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
