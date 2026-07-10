local Context = require('vv-mcp.lsp.context')
local Navigation = require('vv-mcp.lsp.navigation')
local Operations = require('vv-mcp.lsp.operations')

local M = {}

---@param params table
---@return table
function M.request(params)
  local operation = Operations.get(params.operation)
  if not operation then
    return {
      error = {
        code = 'unsupported_operation',
        message = 'Unsupported LSP operation: ' .. tostring(params.operation),
      },
    }
  end

  local context, error = Context.create(params, operation)
  if not context then return { error = error } end

  return Navigation.request(context, operation)
end

return M
