local M = {}

---@param opts? VVMcpConfig
function M.setup(opts)
  local config = require('vv-mcp.config').resolve(opts)
  require('vv-mcp.commands').setup(config)
  require('vv-mcp.lifecycle').setup(config)
end

return M

