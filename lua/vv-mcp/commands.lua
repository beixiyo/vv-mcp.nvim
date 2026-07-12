local Instance = require('vv-mcp.instance')
local Registry = require('vv-mcp.registry')
local Binary = require('vv-mcp.binary')

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
      server = Binary.status(config.server),
    }), vim.log.levels.INFO)
  end, { desc = 'vv-mcp: show current instance information' })

  local function install(force)
    Binary.install(config.server, { force = force }, function(result)
      vim.notify(
        result.ok
            and ('vv-mcp: server %s at %s'):format(result.version, result.path)
            or ('vv-mcp: ' .. result.message),
        result.ok and vim.log.levels.INFO or vim.log.levels.ERROR
      )
    end)
  end
  vim.api.nvim_create_user_command('VVMcpInstall', function() install(false) end, {
    desc = 'vv-mcp: install the matching prebuilt server',
  })
  vim.api.nvim_create_user_command('VVMcpUpdate', function() install(true) end, {
    desc = 'vv-mcp: reinstall the matching prebuilt server',
  })
  vim.api.nvim_create_user_command('VVMcpUninstall', function()
    local removed = Binary.uninstall(config.server)
    vim.notify(
      removed and 'vv-mcp: removed managed server' or 'vv-mcp: no managed server to remove',
      vim.log.levels.INFO
    )
  end, { desc = 'vv-mcp: remove the managed server' })
end

return M
