local Path = require('vv-utils.path')

local M = {}

---@param root string
---@return string
local function project_name(root)
  local name = vim.fs.basename(root)
  name = name:gsub('[^%w._-]+', '-')
  return name ~= '' and name or 'project'
end

---@param fallback string
---@return string[]
local function collect_roots(fallback)
  local seen = { [fallback] = true }
  local roots = { fallback }
  for _, client in ipairs(vim.lsp.get_clients()) do
    local workspace_folders = client.workspace_folders or {}
    for _, folder in ipairs(workspace_folders) do
      local path = folder.uri and vim.uri_to_fname(folder.uri) or nil
      if path then
        path = vim.fs.normalize(path)
        if not seen[path] then
          seen[path] = true
          roots[#roots + 1] = path
        end
      end
    end
  end
  table.sort(roots)
  return roots
end

---@return string[]
local function collect_clients()
  local seen = {}
  local clients = {}
  for _, client in ipairs(vim.lsp.get_clients()) do
    if not seen[client.name] then
      seen[client.name] = true
      clients[#clients + 1] = client.name
    end
  end
  table.sort(clients)
  return clients
end

---@class VVMcpInstance
---@field instanceId string
---@field projectId string
---@field pid integer
---@field socket string
---@field cwd string
---@field roots string[]
---@field lspClients string[]
---@field updatedAt integer

---@return VVMcpInstance
function M.current()
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  local detected_root = Path.get_root() or cwd
  local root = vim.fs.normalize(vim.fn.fnamemodify(detected_root, ':p'))
  local pid = vim.fn.getpid()
  local project_id = project_name(root) .. '-' .. vim.fn.sha256(root):sub(1, 8)

  return {
    instanceId = project_id .. ':' .. pid,
    projectId = project_id,
    pid = pid,
    socket = vim.v.servername,
    cwd = cwd,
    roots = collect_roots(root),
    lspClients = collect_clients(),
    updatedAt = os.time(),
  }
end

return M
