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

<!-- vim-markdown-toc GFM -->

* [Creating a layer](#creating-a-layer)
    * [`enter`, `layer` and `exit` tables](#enter-layer-and-exit-tables)
        * [`opts`](#opts)
            * [`expr`, `silent`, `desc`](#expr-silent-desc)
            * [`nowait`](#nowait)
            * [`after_exit`](#after_exit)
    * [`config` table](#config-table)
        * [`on_enter` and `on_exit`](#on_enter-and-on_exit)
            * [meta-accessors](#meta-accessors)
        * [`timeout`](#timeout)
* [Global variable](#global-variable)
* [Layer object](#layer-object)

<!-- vim-markdown-toc -->

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
       on_enter = function()
          print("Enter layer")
          vim.bo.modifiable = false
       end,
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

**Note:** Only one Layer can be active at a time. The next one will stop the previous.

#### `opts`
`table`

`opts` table modifies the keymap behaviour and accepts the following keys:

##### `expr`, `silent`, `desc`
`boolean`

Built-in map arguments. See:

- `:help :map-<expr>`
- `:help :map-<silent>`
- [desc](https://www.reddit.com/r/neovim/comments/rt0zzh/comment/hqpxolg/?utm_source=share&utm_medium=web2x&context=3)

##### `nowait`
`boolean`

Layer binds its keymaps as buffer local.  This makes flag `nowait` awailable.
See `:help :map-<nowait>`.
This allows, for example bind exit key:

```lua
exit = {
    { 'n', 'q', nil, { nowait = true } }
}
```

which will exit layer, without waiting `&timeoutlen` milliseconds for possible continuation.


##### `after_exit`
`boolean`

**This is exclusive `exit` table key.**

By default, when you press the exit key, Layer executes in the following order:

1. `rhs` of the keymap;
2. `config.on_exit()` function (passed in `config` table, see below);
3. restore original keymaps.

This option allows to change this order the next way:

1. `config.on_exit()` function (passed in `config` table, see below);
2. restore original keymaps;
3. `rhs` of the keymap.

This is always when `rhs` opens new buffer with custom buffer local keymaps. 

For example, exit layer and open [Neogit](https://github.com/TimUntersberger/neogit).
```lua
exit = {
    { 'n', '<Enter>', '<cmd>Neogit<CR>', { after_exit = true } }
}
```
Without this flag **Neogit** opens its buffer in the Layer scope,
and then happens two competing processes in undefined order: Layer tries to save the
original keymaps and set its own, and Neogit tries to set its own keymaps.
Then if Layer managed first, on exiting, it will restore keymaps saved before Neogit
set its own, and Neogit keymaps will be lost: you will get Neogit buffer without Neogit
keybindings. This is shown more clearly in the diagram below.

```
after_exit = false

      Press        Neogit opens      Layer saves      Neogit set        Layer restores
     exit key       new buffer         keymaps         keymaps        keymaps saved in (x)
        :               :                 :               :                   :
--------o---------------o----------------(x)--------------o-------------------o---------->
time
```

For this case, this flag was developed: you first exit the Layer and then open Neogit, and
they don't interfere each other.

```
after_exit = true

             Press             Layer exit and          Neogit opens new buffer
            exit key          restores keymaps             and set keymaps
               :                     :                          :
---------------o---------------------o--------------------------o------------------------>
time
```


### `config` table

#### `on_enter` and `on_exit`
`function | function[]`

`on_enter`/`on_exit` is a function or list of function, that will be executed
on entering / exiting the layer.

Inside the `on_enter` functions the `vim.bo` and `vim.wo` [meta-accessors](https://github.com/nanotee/nvim-lua-guide#using-meta-accessors)
are redefined to work the way you think they should. If you want some option value to be
temporary changed while Layer is active, you need just set it with `vim.bo`/`vim.wo`
meta-accessor. And thats it. All other will be done automatically in the backstage.

##### meta-accessors

Inside the `on_enter` function, the `vim.bo` and `vim.wo` [meta-accessors](https://github.com/nanotee/nvim-lua-guide#using-meta-accessors)
are redefined to work the way you think they should. If you want some option value to be
temporary changed while Layer is active, you need just set it with `vim.bo`/`vim.wo`
meta-accessor. And that's it. All others will be done automatically in the backstage.

For example, temporary unset `modifiable` (local to buffer) option while Layer is active:
```lua
KeyLayer({
   config = {
      on_enter = function()
         vim.bo.modifiable = false
      end
   }
})
```
And that's all, nothing more.

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

---------------------------------------------------------------------------------------
To disable the possibility to edit text while layer is active, you can either manually
unmap desired keys with next snippet:

```lua
local m = {'n', 'x'}

KeyLayer({
    enter = {...},
    layer = {
        {m, 'i'},   {m, 'a'},   {m, 'o'},   {m, 's'},
        {m, 'I'},   {m, 'A'},   {m, 'O'},   {m, 'S'},
        {m, 'gi'},
        {m, '#I'},

        {m, 'c', nil, { nowait = true } },
        {m, 'C'},
        {m, 'cc'},

        {m, 'd',  nil, { nowait = true } },
        {m, 'D'},
        {m, 'x'},
        {m, 'X'},
        ...
    },
    exit = {...}
})
```

Or disable `modifiable` option:
```lua
KeyLayer({
   config = {
      on_enter = function()
         vim.bo.modifiable = false
      end,
   }
   ...
})
```

<!-- vim: set tw=90: -->
