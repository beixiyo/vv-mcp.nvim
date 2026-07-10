local M = {}

---@class VVMcpConfig
---@field enabled boolean 是否登记当前 Neovim 实例 @default true
---@field registry_dir string? 实例 registry 目录；nil 使用 stdpath('state')/vv-mcp/instances @default nil
---@field refresh_events string[] 刷新实例活动状态的 autocmd 事件 @default { 'FocusGained', 'DirChanged', 'LspAttach', 'LspDetach' }

local defaults = {
  enabled = true,
  registry_dir = nil,
  refresh_events = { 'FocusGained', 'DirChanged', 'LspAttach', 'LspDetach' },
}

---@param opts? VVMcpConfig
---@return VVMcpConfig
function M.resolve(opts)
  return vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
end

return M

