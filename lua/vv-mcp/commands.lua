local Instance = require('vv-mcp.instance')
local Registry = require('vv-mcp.registry')
local Binary = require('vv-mcp.binary')

local M = {}

-- 跨 setup 共享：重复 setup 后在途下载仍会拒绝新的安装命令
local installing = false

---@param config VVMcpConfig
function M.setup(config)
  vim.api.nvim_create_user_command('VVMcpRefresh', function()
    if config.enabled then
      Registry.write(config, Instance.current())
    else
      Registry.remove(config)
    end
  end, { force = true, desc = 'vv-mcp: refresh current instance registry' })

  vim.api.nvim_create_user_command('VVMcpInfo', function()
    local instance = Instance.current()
    vim.notify(vim.inspect({
      instance = instance,
      registry = Registry.path(config, instance.pid),
      server = Binary.status(config.server),
    }), vim.log.levels.INFO)
  end, { force = true, desc = 'vv-mcp: show current instance information' })

  local function install(force)
    if installing then
      vim.notify('vv-mcp: server installation already in progress', vim.log.levels.WARN)
      return
    end

    installing = true
    local ok, err = pcall(Binary.install, config.server, {
      force = force,
      on_start = function(info)
        vim.notify(('vv-mcp: downloading server v%s…'):format(info.version), vim.log.levels.INFO)
      end,
    }, function(result)
      installing = false
      vim.notify(
        result.ok
            and ('vv-mcp: server %s at %s'):format(result.version, result.path)
            or ('vv-mcp: ' .. result.message),
        result.ok and vim.log.levels.INFO or vim.log.levels.ERROR
      )
    end)
    if not ok then
      installing = false
      error(err, 0)
    end
  end

  vim.api.nvim_create_user_command('VVMcpInstall', function() install(false) end, {
    force = true,
    desc = 'vv-mcp: install the matching prebuilt server',
  })
  vim.api.nvim_create_user_command('VVMcpUpdate', function() install(true) end, {
    force = true,
    desc = 'vv-mcp: reinstall the matching prebuilt server',
  })
  vim.api.nvim_create_user_command('VVMcpUninstall', function()
    local removed = Binary.uninstall(config.server)
    vim.notify(
      removed and 'vv-mcp: removed managed server' or 'vv-mcp: no managed server to remove',
      vim.log.levels.INFO
    )
  end, { force = true, desc = 'vv-mcp: remove the managed server' })
end

return M
