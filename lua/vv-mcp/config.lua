local M = {}

---@class VVMcpConfig
---@field enabled boolean 是否登记当前 Neovim 实例 @default true
---@field registry_dir string? 实例 registry 目录；nil 使用 stdpath('state')/vv-mcp/instances @default nil
---@field refresh_events string[] 刷新实例活动状态的 autocmd 事件 @default { 'FocusGained', 'DirChanged', 'LspAttach', 'LspDetach' }
---@field lsp VVMcpLspConfig LSP 行为配置
---@field server VVMcpServerConfig 预编译 MCP Server 配置

---@class VVMcpLspConfig
---@field dependency_markers string[] 依赖目录的路径标记，用于区分项目源码和第三方依赖；影响引用过滤与调用层级排序。路径命中任一标记时会被归类为 dependency @default 见下方 defaults.lsp.dependency_markers

---@class VVMcpServerConfig
---@field auto_install boolean 缺失或版本不匹配时自动下载预编译二进制 @default true
---@field install_dir string? 托管二进制目录；nil 使用 ~/.local/bin @default nil
---@field path string? 用户自行管理的 vv-mcp 绝对路径；设置后禁用自动安装 @default nil

local defaults = {
  enabled = true,
  registry_dir = nil,
  refresh_events = { 'FocusGained', 'DirChanged', 'LspAttach', 'LspDetach' },
  server = {
    auto_install = true,
    install_dir = nil,
    path = nil,
  },
  lsp = {
    dependency_markers = {
      '/node_modules/',
      '/.pnpm/',
      '/.cargo/registry/',
      '/rustlib/',
      '/go/pkg/mod/',
      '/.m2/repository/',
      '/.gradle/caches/',
      '/.venv/',
      '/site-packages/',
      '/mason/packages/',
      '/vendor/',
    },
  },
}

local current = vim.deepcopy(defaults)

---@param opts? VVMcpConfig
---@return VVMcpConfig
function M.resolve(opts)
  local config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
  if opts and opts.lsp and opts.lsp.dependency_markers then
    config.lsp.dependency_markers = vim.deepcopy(opts.lsp.dependency_markers)
  end
  current = config
  return config
end

---返回当前 setup 已解析的配置；尚未 setup 时使用默认配置
---@return VVMcpConfig
function M.get()
  return current
end

return M
