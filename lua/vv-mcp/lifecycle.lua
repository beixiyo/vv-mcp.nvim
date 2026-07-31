local Instance = require('vv-mcp.instance')
local Registry = require('vv-mcp.registry')

local M = {}

local generation = 0
local active_config

---@param config VVMcpConfig
function M.setup(config)
  generation = generation + 1
  local current_generation = generation

  if active_config then Registry.remove(active_config) end
  active_config = config
  if not config.enabled then Registry.remove(config) end

  local group = vim.api.nvim_create_augroup('vv-mcp.lifecycle', { clear = true })

  local function refresh()
    if current_generation ~= generation or not config.enabled then return end
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
    callback = function()
      if current_generation == generation then Registry.remove(config) end
    end,
    desc = 'vv-mcp: remove instance registry',
  })
end

return M
