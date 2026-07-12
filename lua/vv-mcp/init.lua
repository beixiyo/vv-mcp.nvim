local M = {}

---@param opts? VVMcpConfig
function M.setup(opts)
  local config = require('vv-mcp.config').resolve(opts)
  require('vv-mcp.commands').setup(config)
  require('vv-mcp.lifecycle').setup(config)
  if config.server.auto_install and not config.server.path then
    vim.schedule(function()
      require('vv-mcp.binary').ensure(config.server, function(result)
        if not result.ok then
          vim.notify('vv-mcp: ' .. result.message, vim.log.levels.WARN)
        elseif result.changed then
          vim.notify('vv-mcp: installed server ' .. result.version, vim.log.levels.INFO)
        end
      end)
    end)
  end
end

---返回 MCP 客户端应使用的 vv-mcp 二进制稳定路径
---@return string path
function M.server_path()
  return require('vv-mcp.binary').path()
end

return M
