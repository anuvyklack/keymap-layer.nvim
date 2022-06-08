local util = require('keymap-layer.util')

---@type function
local termcodes = util.termcodes

---Currently active `keymap.Layer` object if any.
---@type keymap.Layer
_G.active_keymap_layer = nil

---@class keymap.Layer
---@field active boolean If mode is active or not.
---@field enter_keymaps table The keymaps to enter the Layer.
---@field layer_keymaps table The keymaps that are rebounded while Layer is active.
---@field exit_keymaps table The keymaps which are deactivating the Layer.
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
   vim.validate({
      name   = { input.name, 'string', true },
      config = { input.config, 'table', true },
      enter  = { input.enter, 'table', true },
      layer  = { input.layer, 'table' },
      exit   = { input.exit, 'table', true }
   })
   if input.config then
      vim.validate({
         on_enter = { input.config.on_enter, 'function', true },
         on_exit = { input.config.on_exit, 'function', true },
         timeout = { input.config.timeout, { 'boolean', 'number' }, true }
      })
   end

   self.active = false
   self.id = util.generate_id() -- Unique ID for each Layer.
   self.name = input.name
   self.config = input.config or {}
   if type(self.config.timeout) == 'boolean' and self.config.timeout then
      self.config.timeout = vim.o.timeoutlen
   end

   -- Everything to restore when Layer exit, including original keymaps:
   -- global and buffer local.
   self.original = {}

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
         self.exit_keymaps[mode]['<Esc>'] = { '<Nop>' }
      end
   end

   -- Setup keybindings to enter Layer
   if self.enter_keymaps then
      for mode, keymaps in pairs(self.enter_keymaps) do
         if self.config.on_enter then
            vim.keymap.set(mode, self.plug[mode].on_enter, self.config.on_enter)
         else
            self.plug[mode].on_enter = ''
         end

         vim.keymap.set(mode, self.plug[mode].enter, function() self:_enter() end)

         for lhs, map in pairs(keymaps) do
            local rhs, opts = map[1], map[2]
            if rhs ~= '<Nop>' then
               vim.keymap.set(mode, self.plug[mode][lhs], rhs, opts)
            else
               self.plug[mode][lhs] = ''
            end

            vim.keymap.set(mode, lhs, table.concat{
               self.plug[mode].on_enter,
               self.plug[mode][lhs],
               self.plug[mode].enter,
            })
         end
      end
   end

   -- Setup keybindings to exit Layer
   for mode, keymaps in pairs(self.exit_keymaps) do
      if self.config.on_exit then
         vim.keymap.set(mode, self.plug[mode].on_exit, self.config.on_exit)
      else
         self.plug[mode].on_exit = ''
      end

      vim.keymap.set(mode, self.plug[mode].exit, function() self:_exit() end)

      for lhs, map in pairs(keymaps) do
         local rhs, opts = map[1], map[2]
         if rhs ~= '<Nop>' then
            vim.keymap.set(mode, self.plug[mode][lhs], rhs, opts)
         else
            self.plug[mode][lhs] = ''
         end

         self.layer_keymaps[mode][lhs] = { table.concat{
            self.plug[mode][lhs],
            self.plug[mode].on_exit,
            self.plug[mode].exit,
         }}
      end
   end

   -- Since now all exit mappings are incorporated into `self.layer_keymaps`
   -- table, we don't need it anymore.
   self.exit_keymaps = nil

end

---Activate the Layer
function Layer:enter()
   if _G.active_keymap_layer and _G.active_keymap_layer.id == self.id then
      return
   end
   if self.config.on_enter then self.config.on_enter() end
   self:_enter()
end

---Exit the Layer and restore all previous keymaps
function Layer:exit()
   -- assert(self.active, 'The Layer is not active.')
   if not self.active then return end
   if self.timer then
      self.timer:close()
      self.timer = nil
   end
   if self.config.on_exit then
      self.config.on_exit()
   end
   self:_exit()
end

---Add a keymap to the Layer.
---@param mode string
---@param lhs string
---@param rhs function|string
---@param opts? table
function Layer:set_keymap(mode, lhs, rhs, opts)
   if type(mode) == 'table' then
      for _, m in ipairs(mode) do
         self:set_keymap(m, lhs, rhs, opts)
      end
   end

   -- In the output of the `nvim_get_keymap` and `nvim_buf_get_keymap`
   -- functions some keycodes are replaced, for example: `<leader>` and
   -- some are not, like `<Tab>`.  So to avoid this incompatibility better
   -- to apply `termcodes` function on both `lhs` and the received keymap
   -- before comparison.
   lhs = termcodes(lhs)

   if self.config.timeout then
      if not rawget(self.plug[mode], 'timer') then
         vim.keymap.set(mode, self.plug[mode].timer, function() self:_timer() end)
      end
      vim.keymap.set(mode, self.plug[mode][lhs], rhs, opts)

      self.layer_keymaps[mode][lhs] = { table.concat{
         self.plug[mode].timer,
         self.plug[mode][lhs]
      }}
   else
      self.layer_keymaps[mode][lhs] = { rhs, opts }
   end

   if self.active then
      self:_save_original_keymaps()

      local map = self.layer_keymaps[mode][lhs]
      if type(map) == 'table' then
         vim.keymap.set(mode, lhs, unpack(map))
      else
         vim.keymap.set(mode, lhs, map)
      end
   end
end

function Layer:_normalize_input(input)
   for _, mappings_type in ipairs({ 'enter', 'layer', 'exit' }) do
      if input[mappings_type] then
         -- enter_keymaps, layer_keymaps, exit_keymaps
         local keymaps = mappings_type..'_keymaps'
         self[keymaps] = setmetatable({}, {
            __index = function(tbl, mode)
               tbl[mode] = {}
               return tbl[mode]
            end
         })
         for _, map in ipairs(input[mappings_type]) do
            local mode, lhs, rhs, opts = map[1], map[2], map[3] or '<Nop>', map[4]
            if type(mode) == 'table' then
               for _, m in ipairs(mode) do
                  self[keymaps][m][lhs] = { rhs, opts }
               end
            else
               self[keymaps][mode][lhs] = { rhs, opts }
            end
         end
         setmetatable(self[keymaps], nil)
      end
   end
end

function Layer:_enter()
   if _G.active_keymap_layer and _G.active_keymap_layer.id == self.id then
      return
   end
   self.active = true
   _G.active_keymap_layer = self

   self:_save_original_keymaps()

   -- Apply the Layer's keymappings.
   for mode, keymaps in pairs(self.layer_keymaps) do
      for lhs, map in pairs(keymaps) do
         vim.keymap.set(mode, lhs, map[1], map[2])
      end
   end

   -- Save buffer local keymaps on enter to the new buffer while Layer is active.
   self.autocmd = vim.api.nvim_create_autocmd('BufWinEnter', {
      callback = function() self:_save_original_keymaps(true) end
   })
end

function Layer:_exit()
   if not self.active then return end
   for mode, keymaps in pairs(self.layer_keymaps) do
      for lhs, _ in pairs(keymaps) do
         self:_restore_keymap(mode, lhs)
      end
   end
   vim.api.nvim_del_autocmd(self.autocmd)
   self.autocmd = nil
   self.original.keymaps = nil
   self.original.buf_keymaps = nil
   _G.active_keymap_layer = nil
   self.active = false
   -- print(vim.inspect(self))
end

---Restore a keymap overwritten by Layer to its original state.
---@param mode string
---@param lhs string
function Layer:_restore_keymap(mode, lhs)
   if not self.active then return end
   -- lhs = termcodes(lhs)

   local buffers = {}
   for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.fn.buflisted(b) == 1 then
         buffers[b] = true
      end
   end

   for bufnr, _ in pairs(self.original.buf_keymaps) do
      if buffers[bufnr] then  -- if `bufn` buffer still exists
         if type(self.original.buf_keymaps[bufnr][mode][lhs]) == 'table' then
            local map = self.original.buf_keymaps[bufnr][mode][lhs]
            vim.api.nvim_buf_set_keymap(bufnr, mode, lhs, map.rhs, {
               expr = map.expr,
               callback = map.callback,
               noremap = map.noremap,
               script = map.script,
               silent = map.silent,
               nowait = map.nowait
            })
         end
         self.original.buf_keymaps[bufnr][mode][lhs] = nil
      else
         self.original.buf_keymaps[bufnr] = nil
      end
   end

   if type(self.original.keymaps[mode][lhs]) == 'table' then
      local map = self.original.keymaps[mode][lhs]
      vim.api.nvim_set_keymap(mode, lhs, map.rhs, {
         expr = map.expr,
         callback = map.callback,
         noremap = map.noremap,
         script = map.script,
         silent = map.silent,
         nowait = map.nowait
      })
   else
      vim.keymap.del(mode, lhs)
   end
   self.original.keymaps[mode][lhs] = nil
end

--- Save keymappings overwritten by Layer for future restore.
---@param buffer_only? boolean Store only buffer local key mappings.
function Layer:_save_original_keymaps(buffer_only)

   local bufnr = vim.api.nvim_get_current_buf()
   self.original.buf_keymaps = self.original.buf_keymaps or {}
   self.original.buf_keymaps[bufnr] = self.original.buf_keymaps[bufnr] or {}

   self.original.keymaps = self.original.keymaps or {}

   for mode, keymaps in pairs(self.layer_keymaps) do
      self.original.buf_keymaps[bufnr][mode] = self.original.buf_keymaps[bufnr][mode] or {}
      self.original.keymaps[mode] = self.original.keymaps[mode] or {}

      for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
         map.lhs = termcodes(map.lhs)
         if keymaps[map.lhs] and not self.original.buf_keymaps[bufnr][mode][map.lhs] then
            self.original.buf_keymaps[bufnr][mode][map.lhs] = {
               rhs = map.rhs or '',
               expr = map.expr == 1,
               callback = map.callback,
               noremap = map.noremap == 1,
               script = map.script == 1,
               silent = map.silent == 1,
               nowait = map.nowait == 1,
            }
            vim.keymap.del(mode, map.lhs, { buffer = bufnr })
         end
      end

      if not buffer_only then
         for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
            map.lhs = termcodes(map.lhs)
            if keymaps[map.lhs] and not self.original.keymaps[mode][map.lhs] then
               self.original.keymaps[mode][map.lhs] = {
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
   end

   -- To avoid adding into `self.original.buf_keymaps` table already remapped keys
   -- on `Layer:map` method execution while Layer is active.
   for mode, keymaps in pairs(self.layer_keymaps) do
      for lhs, _ in pairs(keymaps) do
         if not buffer_only and not self.original.keymaps[mode][lhs] then
            self.original.keymaps[mode][lhs] = true
         end
         if not self.original.buf_keymaps[bufnr][mode][lhs] then
            self.original.buf_keymaps[bufnr][mode][lhs] = true
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

return Layer
