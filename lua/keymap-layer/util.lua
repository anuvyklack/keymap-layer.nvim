local utils = {}
local id = 0

---Generate ID
---@return integer
function utils.generate_id()
   id = id + 1
   return id
end

---Shortcut to `vim.api.nvim_replace_termcodes`
---@param keys string
---@return string
function utils.termcodes(keys)
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

function utils.unlimited_depth_table()
   return setmetatable({}, mt)
end

---Deep unset metatables for input table all nested tables.
---@param tbl table
function utils.deep_unsetmetatable(tbl)
   for _, subtbl in pairs(tbl) do
      setmetatable(tbl, nil)
      if type(subtbl) == 'table' then
         utils.deep_unsetmetatable(subtbl)
      end
   end
end

---Like `vim.tbl_get` but returns the raw value (got with `rawget` function,
---ignoring  all metatables on the way).
---@param tbl table
---@param ... any
---@return any
---@see :help vim.tbl_get
function utils.tbl_rawget(tbl, ...)
   if tbl == nil then return nil end

   local len = select('#', ...)
   local index = ... -- the first argument of the sequence `...`
   local result = rawget(tbl, index)

   if len == 1 then
      return result
   else
      return utils.tbl_rawget(result, select(2, ...))
   end
end

return utils
