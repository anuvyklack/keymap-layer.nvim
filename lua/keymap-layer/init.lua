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
         self.exit_keymaps[mode]['<Esc>'] = { '<Nop>', { buffer = true } }
      end
   end

   -- Setup keybindings to enter Layer
   if self.enter_keymaps then
      for mode, keymaps in pairs(self.enter_keymaps) do
         vim.keymap.set(mode, self.plug[mode].enter, function() self:enter() end)

         for lhs, map in pairs(keymaps) do
            local rhs, opts = map[1], map[2]
            if rhs ~= '<Nop>' then
               vim.keymap.set(mode, self.plug[mode]['entrance_'..lhs], rhs, opts)
            else
               self.plug[mode]['entrance_'..lhs] = ''
            end

            vim.keymap.set(mode, lhs, table.concat{
               self.plug[mode].enter,
               self.plug[mode]['entrance_'..lhs],
            })
         end
      end
   end

   -- Add timer to layer keybindings
   if self.config.timeout then
      for mode, keymaps in pairs(self.layer_keymaps) do
         if not rawget(self.plug[mode], 'timer') then
            vim.keymap.set(mode, self.plug[mode].timer, function() self:_timer() end)
         end
         for lhs, map in pairs(keymaps) do
            vim.keymap.set(mode, self.plug[mode][lhs], map[1], map[2])

            self.layer_keymaps[mode][lhs] = { table.concat{
               self.plug[mode].timer,
               self.plug[mode][lhs]
            }}
         end
      end
   end

   -- Setup keybindings to exit Layer
   for mode, keymaps in pairs(self.exit_keymaps) do
      vim.keymap.set(mode, self.plug[mode].exit, function() self:exit() end)

      for lhs, map in pairs(keymaps) do
         local rhs, opts = map[1], map[2]
         if rhs ~= '<Nop>' then
            vim.keymap.set(mode, self.plug[mode][lhs], rhs, opts)
         else
            self.plug[mode][lhs] = ''
         end

         self.layer_keymaps[mode][lhs] = { table.concat{
            self.plug[mode][lhs],
            self.plug[mode].exit,
         }}
      end
   end

   -- Since now all exit keymaps are incorporated into `self.layer_keymaps`
   -- table, we don't need it anymore.
   self.exit_keymaps = nil
end

---Activate the Layer
function Layer:enter()
   if _G.active_keymap_layer and _G.active_keymap_layer.id == self.id then
      return
   end
   self.active = true
   _G.active_keymap_layer = self

   if self.config.on_enter then self.config.on_enter() end

   self:_setup_layer_keymaps()
   self:_timer()

   -- Apply Layer keybindings on every visited buffer while Layer is active.
   -- self.autocmd = vim.api.nvim_create_autocmd('BufWinEnter', {
   self.autocmd = vim.api.nvim_create_autocmd('BufEnter', {
      callback = function()
         self:_setup_layer_keymaps()
      end
   })
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

   self:_restore_original_keymaps()

   vim.api.nvim_del_autocmd(self.autocmd)
   self.autocmd = nil
   self.original.buf_keymaps = nil
   self.active = false
   _G.active_keymap_layer = nil

   -- print(vim.inspect(self))
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
         setmetatable(self[keymaps], nil)
      end
   end
end

function Layer:_setup_layer_keymaps()
   self:_save_original_keymaps()

   for mode, keymaps in pairs(self.layer_keymaps) do
      for lhs, map in pairs(keymaps) do
         local rhs, opts = map[1], map[2]

         opts = opts or {} -- just in case
         opts.buffer = true

         vim.keymap.set(mode, lhs, rhs, opts)
      end
   end
end

--- Save keymappings overwritten by Layer for future restore.
function Layer:_save_original_keymaps()

   local bufnr = vim.api.nvim_get_current_buf()
   self.original.buf_keymaps = self.original.buf_keymaps or {}
   self.original.buf_keymaps[bufnr] = self.original.buf_keymaps[bufnr] or {}

   for mode, keymaps in pairs(self.layer_keymaps) do
      self.original.buf_keymaps[bufnr][mode] = self.original.buf_keymaps[bufnr][mode] or {}

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
         end
      end
   end

   -- To avoid adding into `self.original.buf_keymaps` table already remapped keys
   -- on `Layer:map` method execution while Layer is active.
   for mode, keymaps in pairs(self.layer_keymaps) do
      for lhs, _ in pairs(keymaps) do
         if not self.original.buf_keymaps[bufnr][mode][lhs] then
            self.original.buf_keymaps[bufnr][mode][lhs] = true
         end
      end
   end
end

---Restore a keymap overwritten by Layer
function Layer:_restore_original_keymaps()
   if not self.active then return end

   ---Set with 'listed' buffers.
   local buffers = {}
   for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.fn.buflisted(b) == 1 then
         buffers[b] = true
      end
   end

   for mode, keymaps in pairs(self.layer_keymaps) do
      for lhs, _ in pairs(keymaps) do
         for bufnr, _ in pairs(self.original.buf_keymaps) do
            if buffers[bufnr] then  -- if `bufn` buffer still exists
               local map = self.original.buf_keymaps[bufnr][mode][lhs]
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
               self.original.buf_keymaps[bufnr][mode][lhs] = nil
            else
               self.original.buf_keymaps[bufnr] = nil
            end
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
