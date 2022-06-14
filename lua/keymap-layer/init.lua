local util = require 'keymap-layer.util'

---@type function
local termcodes = util.termcodes

local augroup_name = 'Layer'
local augroup_id = vim.api.nvim_create_augroup(augroup_name, { clear = true })

---Currently active `keymap.Layer` object if any.
---@type keymap.Layer
_G.active_keymap_layer = nil

---@class keymap.Layer
---@field active boolean If mode is active or not.
---@field enter_keymaps table The keymaps to enter the Layer.
---@field layer_keymaps table The keymaps that are rebounded while Layer is active.
---@field original table Everything to restore when Layer exit.
local Layer = {}
Layer.__index = Layer
setmetatable(Layer, {
   ---The `new` method which created a new object and call constructor for it.
   ---@param ... table
   ---@return keymap.Layer
   __call = function(_, ...)
      local obj = setmetatable({}, Layer)
      obj:_constructor(...)
      return obj
   end
})

---The Layer constructor
---@param input table
---@return keymap.Layer
function Layer:_constructor(input)
   if input.enter then
      for _, keymap in ipairs(input.enter) do
         local opts = keymap[4] or {}
         vim.validate({
              expr = { opts.expr,   'boolean', true },
            silent = { opts.silent, 'boolean', true },
            nowait = { opts.nowait, 'boolean', true },
              desc = { opts.desc,   'string',  true },
         })
      end
   end
   if input.layer then
      for _, keymap in ipairs(input.layer) do
         local opts = keymap[4] or {}
         vim.validate({
              expr = { opts.expr,   'boolean', true },
            silent = { opts.silent, 'boolean', true },
            nowait = { opts.nowait, 'boolean', true },
              desc = { opts.desc,   'string',  true },
         })
      end
   end
   if input.exit then
      for _, keymap in ipairs(input.exit) do
         local opts = keymap[4] or {}
         vim.validate({
            expr = { opts.expr, 'boolean', true },
            silent = { opts.silent, 'boolean', true },
            nowait = { opts.nowait, 'boolean', true },
            after_exit = { opts.after_exit, 'boolean', true },
            desc = { opts.desc, 'string', true },
         })
      end
   end
   if input.config then
      vim.validate({
         on_enter = { input.config.on_enter, 'function', true },
         on_exit = { input.config.on_exit, 'function', true }
      })
   end

   self.active = false
   self.id = util.generate_id() -- Unique ID for each Layer.
   self.name = input.name
   self.config = input.config or {}
   if type(self.config.timeout) == 'boolean' and self.config.timeout then
      self.config.timeout = vim.o.timeoutlen
   end

   -- Everything to restore when exit Layer.
   self.original = util.unlimited_depth_table()

   -- HACK
   -- I replace in the backstage the `vim.bo` table called inside
   -- `self.config.on_enter()` function with my own.
   if self.config.on_enter then
      -- HACK
      -- The `vim.deepcopy()` rize an error if try to copy `getfenv()`
      -- environment with next snippet:
      -- ```
      --    local env = vim.deepcopy(getfenv())
      -- ```
      -- But `vim.tbl_deep_extend` function makes a copy if extend `getfenv()`
      -- with not empty table; another way, it returns the reference to the
      -- original table.
      local env = vim.tbl_deep_extend('force', getfenv(), {
         vim = {
            bo = {},
            wo = {}
         }
      })
      env.vim.bo = setmetatable({}, {
         __newindex = function(_, option, value)
            self:_set_buf_option(nil, option, value)

            vim.api.nvim_create_autocmd('BufEnter', {
               group = augroup_id,
               desc = string.format('set "%s" buffer option', option),
               callback = function(input)
                  self:_set_buf_option(input.buf, option, value)
               end
            })
         end
      })
      env.vim.wo = setmetatable({}, {
         __newindex = function(_, option, value)
            self:_set_win_option(nil, option, value)

            vim.api.nvim_create_autocmd('WinEnter', {
               group = augroup_id,
               desc = string.format('set "%s" window option', option),
               callback = function(input)
                  self:_set_win_option(input.buf, option, value)
               end
            })
         end
      })
      setfenv(self.config.on_enter, env)
   end
   if self.config.on_exit then
      local env = vim.tbl_deep_extend('force', getfenv(), {
         vim = {
            bo = {},
            wo = {}
         }
      })
      env.vim.bo = setmetatable({}, {
         __newindex = function(_, option, _)
            util.warn(string.format("You don't need to restore vim.bo.%s option in on_exit() function. Reed more in documentation.", option))
         end
      })
      env.vim.wo = setmetatable({}, {
         __newindex = function(_, option, _)
            util.warn(string.format("You don't need to restore vim.wo.%s option in on_exit() function. Reed more in documentation.", option))
         end
      })
      setfenv(self.config.on_exit, env)
   end

   -- Table with all left hand sides of key mappings of the type `<Plug>...`.
   -- Pattern: self.plug.mode.key
   self.plug = setmetatable({}, {
      __index = function (t, mode)
         t[mode] = setmetatable({}, {
            __index = function (t_mode, key)
               t_mode[key] = ('<Plug>(Layer%s_%s)'):format(self.id, key)
               return t_mode[key]
            end
         })
         return t[mode]
      end
   })

   if input.layer_keymaps then
      -- When input was passed already in the internal form.
      self.enter_keymaps = input.enter_keymaps
      self.layer_keymaps = input.layer_keymaps
      self.exit_keymaps  = input.exit_keymaps
   else
      self:_normalize_input(input)
   end

   -- Setup <Esc> key to exit the Layer if no one exit key have been passed.
   if not self.exit_keymaps then
      self.exit_keymaps = {}
      for mode, _ in pairs(self.layer_keymaps) do
         self.exit_keymaps[mode] = {}
         self.exit_keymaps[mode]['<Esc>'] = { '<Nop>', { buffer = true } }
      end
   end

   -- Setup keybindings to enter Layer
   if self.enter_keymaps then
      for mode, keymaps in pairs(self.enter_keymaps) do
         vim.keymap.set(mode, self.plug[mode].enter, function() self:enter() end)

         for lhs, map in pairs(keymaps) do
            local rhs, opts = map[1], map[2]

            local expr   = opts.expr
            local silent = opts.silent
            local desc   = opts.desc
            local nowait = opts.nowait

            if rhs ~= '<Nop>' then
               vim.keymap.set(mode, self.plug[mode]['entrance_'..lhs], rhs, { expr = expr })
            else
               self.plug[mode]['entrance_'..lhs] = ''
            end

            vim.keymap.set(mode, lhs, table.concat{
               self.plug[mode].enter,
               self.plug[mode]['entrance_'..lhs],
            }, { nowait = nowait, silent = silent, desc = desc })
         end
      end
   end

   -- Setup Layer keybindings
   -- Add timer to layer keybindings
   if self.config.timeout then
      for mode, keymaps in pairs(self.layer_keymaps) do
         if not util.tbl_rawget(self.plug, mode, 'timer') then
            vim.keymap.set(mode, self.plug[mode].timer, function() self:_timer() end)
         end

         for lhs, map in pairs(keymaps) do
            local rhs, opts = map[1], map[2]

            local expr   = opts.expr
            local silent = opts.silent
            local desc   = opts.desc
            local nowait = opts.nowait

            vim.keymap.set(mode, self.plug[mode][lhs], rhs, { expr = expr })

            self.layer_keymaps[mode][lhs] = {
               table.concat{
                  self.plug[mode].timer,
                  self.plug[mode][lhs]
               },
               { nowait = nowait, silent = silent, desc = desc }
            }
         end
      end
   end

   -- Setup keybindings to exit Layer
   if self.exit_keymaps then
      for mode, keymaps in pairs(self.exit_keymaps) do
         vim.keymap.set(mode, self.plug[mode].exit, function() self:exit() end)

         for lhs, map in pairs(keymaps) do
            local rhs, opts = map[1], map[2]

            local expr = opts.expr
            local silent = opts.silent
            local desc = opts.desc
            local nowait = opts.nowait
            local after_exit = opts.after_exit

            if rhs and rhs ~= '<Nop>' then
               vim.keymap.set(mode, self.plug[mode][lhs], rhs, { expr = expr })
            else
               self.plug[mode][lhs] = ''
            end

            if after_exit then
               rhs = table.concat{
                  self.plug[mode].exit,
                  self.plug[mode][lhs],
               }
            else
               rhs = table.concat{
                  self.plug[mode][lhs],
                  self.plug[mode].exit,
               }
            end

            self.layer_keymaps[mode][lhs] =
               { rhs, { nowait = nowait, silent = silent, desc = desc } }

         end
      end
   end

   -- Since now all exit keymaps are incorporated into `self.layer_keymaps`
   -- table, we don't need it anymore.
   self.exit_keymaps = nil

   self:_debug('Layer:_constructor', self)
end

---Activate the Layer
function Layer:enter()
   if _G.active_keymap_layer and _G.active_keymap_layer.id == self.id then
      return
   end
   self.active = true
   _G.active_keymap_layer = self

   if self.config.on_enter then self.config.on_enter() end

   local bufnr = vim.api.nvim_get_current_buf()
   self:_setup_layer_keymaps(bufnr)
   self:_timer()

   -- Apply Layer keybindings on every visited buffer while Layer is active.
   vim.api.nvim_create_autocmd('BufEnter', {
      group = augroup_id,
      desc = 'setup Layer keymaps',
      callback = function(input)
         self:_setup_layer_keymaps(input.buf)
      end
   })

   self:_debug('Layer:enter', vim.api.nvim_get_autocmds({ group = augroup_name }))
end

---Exit the Layer and restore all previous keymaps
function Layer:exit()
   -- assert(self.active, 'The Layer is not active.')
   if not self.active then return end

   if self.timer then
      self.timer:close()
      self.timer = nil
   end

   if self.config.on_exit then self.config.on_exit() end
   self:_restore_original()


   vim.api.nvim_clear_autocmds({ group = augroup_id })
   self.original.buf_keymaps = nil
   self.active = false
   _G.active_keymap_layer = nil

   self:_debug('Layer:exit', self)
end

---Save original boffer option value and set the new one.
---@param bufnr number|nil buffer id; if `nil` the current buffer used
---@param option string the buffer option to set
---@param value any the value of the option
function Layer:_set_buf_option(bufnr, option, value)
   bufnr = bufnr or vim.api.nvim_get_current_buf()
   if util.tbl_rawget(self.original, 'buf_options', bufnr, option) then
      return
   end
   self.original.buf_options[bufnr][option] = vim.bo[bufnr][option]
   vim.bo[bufnr][option] = value
end

---Save original window option value and set the new one.
---@param winnr number|nil window id; if `nil` the current window used
---@param option string the window option to set
---@param value any the value of the option
function Layer:_set_win_option(winnr, option, value)
   winnr = winnr or vim.api.nvim_get_current_win()
   if util.tbl_rawget(self.original, 'win_options', winnr, option) then
      return
   end
   self.original.win_options[winnr][option] = vim.wo[winnr][option]
   vim.wo[winnr][option] = value
end

function Layer:_normalize_input(input)
   for _, mappings_type in ipairs({ 'enter', 'layer', 'exit' }) do
      if input[mappings_type] then
         -- enter_keymaps, layer_keymaps, exit_keymaps
         local keymaps = mappings_type..'_keymaps'

         self[keymaps] = util.unlimited_depth_table()

         for _, map in ipairs(input[mappings_type]) do
            local mode, lhs, rhs, opts = map[1], map[2], map[3] or '<Nop>', map[4] or {}

            -- In the output of the `nvim_get_keymap` and `nvim_buf_get_keymap`
            -- functions some keycodes are replaced, for example: `<leader>` and
            -- some are not, like `<Tab>`.  So to avoid this incompatibility better
            -- to apply `termcodes` function on both `lhs` and the received keymap
            -- before comparison.
            lhs = termcodes(lhs)

            if type(mode) == 'table' then
               for _, m in ipairs(mode) do
                  self[keymaps][m][lhs] = { rhs, opts }
               end
            else
               self[keymaps][mode][lhs] = { rhs, opts }
            end
         end

         util.deep_unsetmetatable(self[keymaps])
      end
   end
end

---Setup layer keymaps for buffer with number `bufnr`
---@param bufnr number the buffer ID
function Layer:_setup_layer_keymaps(bufnr)
   -- If original keymaps for `bufnr` buffer are saved,
   -- then we have already set keymaps for that buffer.
   if util.tbl_rawget(self.original, 'buf_keymaps', bufnr) then return end

   self:_save_original_keymaps(bufnr)

   for mode, keymaps in pairs(self.layer_keymaps) do
      for lhs, map in pairs(keymaps) do
         local rhs, opts = map[1], map[2]
         opts.buffer = bufnr
         vim.keymap.set(mode, lhs, rhs, opts)
      end
   end
end

---Save key mappings overwritten by Layer for the buffer with number `bufnr` for
---future restore.
---@param bufnr number the buffer ID for which to save keymaps
function Layer:_save_original_keymaps(bufnr)
   for mode, keymaps in pairs(self.layer_keymaps) do
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
         map.lhs = termcodes(map.lhs)
         if keymaps[map.lhs] and
            not util.tbl_rawget(self.original, 'buf_keymaps', bufnr, mode, map.lhs)
         then
            self.original.buf_keymaps[bufnr][mode][map.lhs] = {
               rhs = map.rhs or '',
               expr = map.expr == 1,
               callback = map.callback,
               noremap = map.noremap == 1,
               script = map.script == 1,
               silent = map.silent == 1,
               nowait = map.nowait == 1,
            }
         end
      end
   end

   -- To avoid adding into `self.original.buf_keymaps` table already remapped keys
   -- on `Layer:map` method execution while Layer is active.
   for mode, keymaps in pairs(self.layer_keymaps) do
      for lhs, _ in pairs(keymaps) do
         if not util.tbl_rawget(self.original.buf_keymaps, bufnr, mode, lhs) then
            self.original.buf_keymaps[bufnr][mode][lhs] = true
         end
      end
   end
end

---Restore original keymaps and options overwritten by Layer
function Layer:_restore_original()
   if not self.active then return end

   ---Set with 'listed' buffers.
   local listed_buffers = {}
   for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.fn.buflisted(b) == 1 then
         listed_buffers[b] = true
      end
   end

   -- Restore keymaps
   for mode, keymaps in pairs(self.layer_keymaps) do
      for lhs, _ in pairs(keymaps) do
         for bufnr, _ in pairs(self.original.buf_keymaps) do
            if listed_buffers[bufnr] then  -- if `bufnr` buffer still exists
               local map = util.tbl_rawget(self.original.buf_keymaps, bufnr, mode, lhs)
               if type(map) == 'table' then
                  vim.api.nvim_buf_set_keymap(bufnr, mode, lhs, map.rhs, {
                     expr = map.expr,
                     callback = map.callback,
                     noremap = map.noremap,
                     script = map.script,
                     silent = map.silent,
                     nowait = map.nowait
                  })
               else
                  vim.keymap.del(mode, lhs, { buffer = bufnr })
               end
            end
         end
      end
   end

   -- Restore buffer options
   for bufnr, options in pairs(self.original.buf_options) do
      if listed_buffers[bufnr] then
         for option, value in pairs(options) do
            vim.bo[bufnr][option] = value
         end
      end
   end

   -- Restore window options
   for winnr, options in pairs(self.original.win_options) do
      if vim.api.nvim_win_is_valid(winnr) then
         for option, value in pairs(options) do
            vim.wo[winnr][option] = value
         end
      end
   end
end

function Layer:_timer()
   if not self.config.timeout then return end

   if self.timer then
      self.timer:again()
   else
      self.timer = vim.loop.new_timer()
      self.timer:start(self.config.timeout, self.config.timeout,
                       vim.schedule_wrap(function() self:exit() end))
   end
end

function Layer:_debug(...)
   if self.config.debug then
      print('---------------------------------[keymap-layer]---------------------------------')
      for _, line in ipairs({...}) do
         vim.pretty_print(line)
      end
   end
end

return Layer
