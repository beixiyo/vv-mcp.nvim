local Navigation = require('vv-mcp.lsp.navigation')

local M = {}

---@param context VVMcpLspContext
---@param operation VVMcpLspOperation
---@return table
function M.request(context, operation)
  return Navigation.request(context, operation)
end

return M
