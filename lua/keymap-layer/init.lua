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
            desc = { opts.desc, 'string', true },
         })
      end
   end
   if input.config then
      vim.validate({
         on_enter = { input.config.on_enter, { 'function', 'table' }, true },
         on_exit  = { input.config.on_exit,  { 'function', 'table' }, true }
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
   self.original = {
      buf_keymaps = util.unlimited_depth_table(),
      o  = {}, go = {}, bo = {}, wo = {}
   }

   -- HACK
   -- I replace in the backstage the `vim.bo` table called inside
   -- `self.config.on_enter()` function with my own.
   if self.config.on_enter then
      if type(self.config.on_enter) == 'function' then
         self.config.on_enter = { self.config.on_enter }
      end

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
         vim = { o = {}, go = {}, bo = {}, wo = {} }
      })
      env.vim.o  = self:_get_meta_accessor('o')
      env.vim.go = self:_get_meta_accessor('go')
      env.vim.bo = self:_get_meta_accessor('bo')
      env.vim.wo = self:_get_meta_accessor('wo')

      for _, fun in pairs(self.config.on_enter) do
         setfenv(fun, env)
      end
   end
   if self.config.on_exit then
      if type(self.config.on_exit) == 'function' then
         self.config.on_exit = { self.config.on_exit }
      end

      local env = vim.tbl_deep_extend('force', getfenv(), {
         vim = { o = {}, go = {}, bo = {}, wo = {} }
      })
      env.vim.o  = util.disable_meta_accessor('o')
      env.vim.go = util.disable_meta_accessor('go')
      env.vim.bo = util.disable_meta_accessor('bo')
      env.vim.wo = util.disable_meta_accessor('wo')

      for _, fun in pairs(self.config.on_exit) do
         setfenv(fun, env)
      end
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

            if mode == 'o' then -- operator-pending mode
               local function execute_operator_and_enter()
                  local operator = vim.v.operator

                  -- Exit operator-pending mode.
                  vim.api.nvim_feedkeys(termcodes('<Esc>'), 'tn', false)

                  -- If operator was 'c' (change) then on exiting Insert mode
                  -- we have moved one character back, and need to move one
                  -- character forward to return in place.
                  if operator == 'c' then
                     vim.api.nvim_feedkeys('l', 'tn', false)
                  end

                  -- Execute operator + motion.
                  local keys = termcodes(operator..self.plug[mode]['entrance_'..lhs])
                  vim.api.nvim_feedkeys(keys, '', false)

                  self:enter() -- Enter layer
               end

               vim.keymap.set(mode, lhs, execute_operator_and_enter,
                              { nowait = nowait, silent = silent, desc = desc })
            else
               vim.keymap.set(mode, lhs, table.concat{
                     self.plug[mode].enter,
                     self.plug[mode]['entrance_'..lhs],
                  }, { nowait = nowait, silent = silent, desc = desc })
            end
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

            if rhs and rhs ~= '<Nop>' then
               vim.keymap.set(mode, self.plug[mode][lhs], rhs, { expr = expr })
            else
               self.plug[mode][lhs] = ''
            end

            rhs = table.concat{
               self.plug[mode].exit,
               self.plug[mode][lhs],
            }

            self.layer_keymaps[mode][lhs] =
               { rhs, { nowait = nowait, silent = silent, desc = desc } }

         end
      end
   end

   -- Since now all exit keymaps are incorporated into `self.layer_keymaps`
   -- table, we don't need it anymore.
   self.exit_keymaps = nil

   -- self:_debug('Layer:_constructor', self)
end

---Activate the Layer
function Layer:enter()
   if _G.active_keymap_layer and _G.active_keymap_layer.id == self.id then
      return
   end
   self.active = true
   _G.active_keymap_layer = self

   if self.config.on_enter then
      for _, fun in pairs(self.config.on_enter) do
         fun()
      end
   end

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

   self:_debug('Layer:enter', self)
   self:_debug('Layer:enter', vim.api.nvim_get_autocmds({ group = augroup_name }))
end

---Exit the Layer and restore all previous keymaps
function Layer:exit()
   if not self.active then return end

   if self.timer then
      self.timer:close()
      self.timer = nil
   end

   if self.config.on_exit then
      for _, fun in pairs(self.config.on_exit) do
         fun()
      end
   end

   self:_restore_original()

   vim.api.nvim_clear_autocmds({ group = augroup_id })

   self.original = {
      buf_keymaps = util.unlimited_depth_table(),
      o  = {}, go = {}, bo = {}, wo = {}
   }

   self.active = false
   _G.active_keymap_layer = nil

   self:_debug('Layer:exit', self)
end

---Returns meta-accessor for vim options
---@param accessor string One from: 'o', 'go', 'bo', 'wo'
---@return any
function Layer:_get_meta_accessor(accessor)
   local function set_buf_option(opt, val)
      local bufnr = vim.api.nvim_get_current_buf()
      self.original.bo[bufnr] = self.original.bo[bufnr] or {}
      if self.original.bo[bufnr][opt] then return end
      self.original.bo[bufnr][opt] = vim.api.nvim_buf_get_option(bufnr, opt)
      vim.api.nvim_buf_set_option(bufnr, opt, val)
   end

   local function set_win_option(opt, val)
      local winnr = vim.api.nvim_get_current_win()
      self.original.wo[winnr] = self.original.wo[winnr] or {}
      if self.original.wo[winnr][opt] then return end
      self.original.wo[winnr][opt] = vim.api.nvim_win_get_option(winnr, opt)
      vim.api.nvim_win_set_option(winnr, opt, val)
   end

   local ma = {
      bo = util.make_meta_accessor(
         function(opt)
            assert(type(opt) ~= 'number',
               '[keymap-layer.nvim] "vim.bo[bufnr]" meta-aссessor in config.on_enter() function is forbiden, use "vim.bo" instead')
            return vim.api.nvim_buf_get_option(0, opt)
         end,
         function(opt, val)
            set_buf_option(opt, val)

            vim.api.nvim_create_autocmd('BufEnter', {
               group = augroup_id,
               desc = string.format('set "%s" buffer option', opt),
               callback = function()
                  set_buf_option(opt, val)
               end
            })
         end
      ),
      wo = util.make_meta_accessor(
         function(opt)
            assert(type(opt) ~= 'number',
               '[keymap-layer.nvim] "vim.wo[winnr]" meta-aссessor in config.on_enter() function is forbiden, use "vim.wo" instead')
            return vim.api.nvim_win_get_option(0, opt)
         end,
         function(opt, val)
            set_win_option(opt, val)

            vim.api.nvim_create_autocmd('WinEnter', {
               group = augroup_id,
               desc = string.format('set "%s" window option', opt),
               callback = function()
                  set_win_option(opt, val)
               end
            })
         end
      ),
      go = util.make_meta_accessor(
         function(opt)
            return vim.api.nvim_get_option_value(opt, { scope = 'global' })
         end,
         function(opt, val)
            self.original.go[opt] = vim.api.nvim_get_option_value(opt, { scope = 'global' })
            vim.api.nvim_set_option_value(opt, val, { scope = 'global' })
         end
      ),
       o = util.make_meta_accessor(
         function(opt)
            return vim.api.nvim_get_option_value(opt, {})
         end,
         function(opt, val)
            self.original.o[opt] = vim.api.nvim_get_option_value(opt, {})
            vim.api.nvim_set_option_value(opt, val, {})
         end
      )
   }

   return ma[accessor]
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
   if util.tbl_rawget(self.original.buf_keymaps, bufnr) then return end

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
            not util.tbl_rawget(self.original.buf_keymaps, bufnr, mode, map.lhs)
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

   -- Restore options
   for opt, val in pairs(self.original.o) do
      vim.api.nvim_set_option_value(opt, val, {})
   end

   -- Restore global options
   for opt, val in pairs(self.original.go) do
      vim.api.nvim_set_option_value(opt, val, { scope = 'global' })
   end

   -- Restore buffer options
   for bufnr, options in pairs(self.original.bo) do
      if listed_buffers[bufnr] then
         for opt, val in pairs(options) do
            vim.api.nvim_buf_set_option(bufnr, opt, val)
         end
      end
   end

   -- Restore window options
   for winnr, options in pairs(self.original.wo) do
      if vim.api.nvim_win_is_valid(winnr) then
         for opt, val in pairs(options) do
            vim.api.nvim_win_set_option(winnr, opt, val)
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
