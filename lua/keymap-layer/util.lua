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

return utils
