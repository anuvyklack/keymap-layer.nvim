local util = {}
local id = 0

---@param msg string
function util.warn(msg)
   vim.schedule(function()
      vim.notify_once('[Hydra] ' .. msg, vim.log.levels.WARN)
   end)
end

---Generate ID
---@return integer
function util.generate_id()
   id = id + 1
   return id
end

---Shortcut to `vim.api.nvim_replace_termcodes`
---@param keys string
---@return string
function util.termcodes(keys)
   return vim.api.nvim_replace_termcodes(keys, true, true, true)
end

-- Recursive subtables
local mt = {}
function mt.__index(self, subtbl)
   self[subtbl] = setmetatable({}, {
      __index = mt.__index
   })
   return self[subtbl]
end

function util.unlimited_depth_table()
   return setmetatable({}, mt)
end

---Recursively unset metatable for the input table and all nested tables.
---@param tbl table
function util.deep_unsetmetatable(tbl)
   for _, subtbl in pairs(tbl) do
      setmetatable(tbl, nil)
      if type(subtbl) == 'table' then
         util.deep_unsetmetatable(subtbl)
      end
   end
end

---Like `vim.tbl_get` but returns the raw value (got with `rawget` function,
---ignoring  all metatables on the way).
---@param tbl table
---@param ... any
---@return any
---@see :help vim.tbl_get
function util.tbl_rawget(tbl, ...)
   if tbl == nil then return nil end

   local len = select('#', ...)
   local index = ... -- the first argument of the sequence `...`
   local result = rawget(tbl, index)

   if len == 1 then
      return result
   else
      return util.tbl_rawget(result, select(2, ...))
   end
end

function util.make_meta_accessor(get, set)
   return setmetatable({}, {
      __index = not get and nil or function(_, k) return get(k) end,
      __newindex = not set and nil or function(_, k, v) return set(k, v) end
   })
end

---@param accessor_name string
---@return MetaAccessor
function util.disable_meta_accessor(accessor_name)
   local function disable()
      util.warn(string.format(
         '"vim.%s" meta-accessor is disabled inside config.on_exit() function',
         accessor_name))
   end

   return util.make_meta_accessor(disable, disable)
end

---@param func? function
---@param new_fn function
---@return function
function util.add_hook_before(func, new_fn)
   if func then
      return function(...)
         new_fn(...)
         return func(...)
      end
   else
      return new_fn
   end
end

return util
