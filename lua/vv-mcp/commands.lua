local Instance = require('vv-mcp.instance')
local Registry = require('vv-mcp.registry')

local M = {}

---@param config VVMcpConfig
function M.setup(config)
  vim.api.nvim_create_user_command('VVMcpRefresh', function()
    Registry.write(config, Instance.current())
  end, { desc = 'vv-mcp: refresh current instance registry' })

  vim.api.nvim_create_user_command('VVMcpInfo', function()
    local instance = Instance.current()
    vim.notify(vim.inspect({
      instance = instance,
      registry = Registry.path(config, instance.pid),
    }), vim.log.levels.INFO)
  end, { desc = 'vv-mcp: show current instance information' })
end

return M

