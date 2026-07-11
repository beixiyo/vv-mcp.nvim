---统一判断 LSP 返回路径属于工作区、依赖还是外部位置
local Config = require('vv-mcp.config')
local Normalize = require('vv-mcp.lsp.normalize')

local M = {}

local function is_under(root, path)
  root = Normalize.wire_path(vim.fs.normalize(root)):gsub('/+$', '')
  path = Normalize.wire_path(vim.fs.normalize(path))
  return path == root or path:sub(1, #root + 1) == root .. '/'
end

---返回规范化路径的来源分类
---@param client vim.lsp.Client
---@param path string 原生路径或规范化传输路径
---@return 'workspace'|'dependency'|'external' origin
function M.classify(client, path)
  local wire_path = Normalize.wire_path(vim.fs.normalize(path))
  for _, marker in ipairs(Config.get().lsp.dependency_markers) do
    if wire_path:find(Normalize.wire_path(marker), 1, true) then return 'dependency' end
  end

  if client.root_dir and is_under(client.root_dir, path) then return 'workspace' end
  for _, folder in ipairs(client.workspace_folders or {}) do
    if is_under(vim.uri_to_fname(folder.uri), path) then return 'workspace' end
  end
  return 'external'
end

return M
