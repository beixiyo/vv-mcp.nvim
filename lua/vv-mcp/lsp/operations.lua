local M = {}

---@class VVMcpLspOperation
---@field name string
---@field method string
---@field requires_position boolean

---@type table<string, VVMcpLspOperation>
local operations = {
  definition = {
    name = 'definition',
    method = 'textDocument/definition',
    requires_position = true,
  },
  declaration = {
    name = 'declaration',
    method = 'textDocument/declaration',
    requires_position = true,
  },
  implementation = {
    name = 'implementation',
    method = 'textDocument/implementation',
    requires_position = true,
  },
  references = {
    name = 'references',
    method = 'textDocument/references',
    requires_position = true,
  },
}

---@param name string
---@return VVMcpLspOperation?
function M.get(name)
  return operations[name]
end

return M
