local M = {}

local setup_generation = 0
local cancel_auto_install

---@param opts? VVMcpOpts
function M.setup(opts)
  setup_generation = setup_generation + 1
  local generation = setup_generation
  if cancel_auto_install then
    cancel_auto_install()
    cancel_auto_install = nil
  end

  local config = require('vv-mcp.config').resolve(opts)

  require('vv-mcp.commands').setup(config)
  require('vv-mcp.lifecycle').setup(config)

  if config.enabled and config.server.auto_install and not config.server.path then
    vim.schedule(function()
      if generation ~= setup_generation then return end

      local completed = false
      local cancel = require('vv-mcp.binary').ensure(config.server, function(result)
        completed = true
        if generation ~= setup_generation then return end
        cancel_auto_install = nil
        if not result.ok then
          vim.notify('vv-mcp: ' .. result.message, vim.log.levels.WARN)
        elseif result.changed then
          vim.notify('vv-mcp: installed server ' .. result.version, vim.log.levels.INFO)
        end
      end)

      if generation == setup_generation and not completed then
        cancel_auto_install = cancel
      elseif generation ~= setup_generation then
        cancel()
      end
    end)
  end
end

---获取当前配置（只读副本）；尚未 setup 时为默认配置
---@return VVMcpConfig
function M.get_config()
  return vim.deepcopy(require('vv-mcp.config').get())
end

---返回 MCP 客户端应使用的 vv-mcp 二进制稳定路径
---@return string path
function M.server_path()
  return require('vv-mcp.binary').path(require('vv-mcp.config').get().server)
end

return M
