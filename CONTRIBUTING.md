# Notes about the internal structure of the code

## How key mappings stores inside

The Layer accepts keymaps in the one form, but stores them internally in the another. 
The `Layer:_normalize_input()` method is responsible for this.  Notice, that terminal
codes are also escaped.  

```
    -----------------------------+------------------------------------
               Input             |              Internal
    -----------------------------+------------------------------------
                                 |
       {mode, lhs, rhs, opts}    |    mode = { lhs = {rhs, opts} }
                                 |
    -----------------------------+------------------------------------
                                 |
                                 |      enter_keymaps = {
                                 |         n = {
       enter = {                 |            zl = {'zl', {}},
          {'n', 'zl', 'zl'},     |            zh = {'zh', {}},
          {'n', 'zh', 'zh'},     |            gz = {'<Nop>', {}}
          {'n', 'gz'},           |         }
       },                        |      },
       layer = {                 |      layer_keymaps = {
          {'n', 'l', 'zl'},      |         n = {
          {'n', 'h', 'zh'},      |            l = {'zl', {}},
       },                        |            h = {'zh', {}}
       exit = {                  |         }
          {'n', '<Esc>'},        |      },
          {'n', 'q'}             |      exit_keymaps = {
       }                         |         n = {
                                 |            ['\27'] = {'<Nop>', {}},
                                 |            q = {'<Nop>', {}}
                                 |         }
                                 |      }
                                 |
```

It allows utilize built-in Lua table properties, and simplifies such things like get
desired normal mode keybinding without looping through the whole list every time.

## Dealing with original key mappings

The Layer owerwrite global key mappings. But buffer local key bindings are of the higher
priority. 
So on activating Layer, the buffer local key mappings of the current buffer are "cutting"
(i.e. deleting) and "pasting" into `self.original.buf_keymaps[buffer]` table.
While Layer is active, this happens to all visited buffers: on entering a new buffer,
the buffer local key bindings, that are remapped by Layer are "cut" and "paste" into
`self.original.buf_keymaps[new_buffer]` table.

On deactivating Layer, the buffer local key bindings that were "cut" are restoring where
they were for all buffers that are still listed. 

`self.original.keymaps` and `self.original.buf_keymaps` tables has the next structure:

``` lua
    self.original.keymaps = {
       n = { -- normal mode
          l = {...},
          h = true,
          ['<Esc>'] = {...},
          q = true
       }
    }

    self.original.buf_keymaps = {
       3 = { -- bufnr
          n = { -- normal mode
             l = true,
             h = {...},
             ['\27'] = true, -- <Esc>
             q = true,
          }
       }
       127 = { -- bufnr
          n = { -- normal mode
             l = true,
             h = {...},
             ['\27'] = true, -- <Esc>
             q = true,
          }
       }
    }
```

- `3` and `127` are buffer numbers for which buffer local mappings are stored;
- `{...}` denotes existing keymap stored for future restore;
- `true` is a placeholder, denotes that there is no specific keymap map for this lhs.


<!-- vim: set tw=90: -->
