local Instance = require('vv-mcp.instance')
local Registry = require('vv-mcp.registry')

local M = {}

---@param config VVMcpConfig
function M.setup(config)
  local group = vim.api.nvim_create_augroup('vv-mcp.lifecycle', { clear = true })

  local function refresh()
    if not config.enabled then return end
    Registry.write(config, Instance.current())
  end

  refresh()

  vim.api.nvim_create_autocmd(config.refresh_events, {
    group = group,
    callback = function() vim.schedule(refresh) end,
    desc = 'vv-mcp: refresh instance registry',
  })

  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function() Registry.remove(config) end,
    desc = 'vv-mcp: remove instance registry',
  })
end

return M

