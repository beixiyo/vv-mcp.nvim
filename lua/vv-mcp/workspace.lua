---文件与目录重命名的 LSP 预览、磁盘应用和单次事务管理
---
---遵循 workspace/willRenameFiles → WorkspaceEdit → 文件移动 →
---workspace/didRenameFiles 的协议顺序，并在任一写入前生成无副作用预览
local Fs = require('vv-utils.fs')
local FileOperations = require('vv-utils.lsp.file_operations')
local Instance = require('vv-mcp.instance')
local Normalize = require('vv-mcp.lsp.normalize')
local WorkspaceEdit = require('vv-utils.lsp.workspace_edit')

local M = {}
local transactions = {}
local ttl_seconds = 300

local function error_result(code, message)
  return { error = { code = code, message = message } }
end

local function purge_expired()
  local now = os.time()
  for id, transaction in pairs(transactions) do
    if now > transaction.expires_at then transactions[id] = nil end
  end
end

local function normalize_path(value)
  if type(value) ~= 'string' or value == '' then return nil end
  local path = value:match('^file://') and vim.uri_to_fname(value) or value
  local absolute = path:sub(1, 1) == '/' or path:match('^%a:[/\\]') ~= nil
  if not absolute then return nil end
  path = vim.fs.normalize(path)
  if vim.uv.fs_lstat(path) then return vim.fs.normalize(vim.fn.resolve(path)) end
  local parent = vim.fs.normalize(vim.fn.resolve(vim.fs.dirname(path)))
  return vim.fs.joinpath(parent, vim.fs.basename(path))
end

local function is_inside(path, root)
  path = vim.fs.normalize(path)
  root = vim.fs.normalize(root):gsub('/+$', '')
  return path == root or path:sub(1, #root + 1) == root .. '/'
end

local function shared_root(old_path, new_path)
  for _, root in ipairs(Instance.current().roots) do
    if is_inside(old_path, root) and is_inside(new_path, root) then return root end
  end
  return nil
end

local function stat_snapshot(path)
  local stat = vim.uv.fs_lstat(path)
  if not stat then return nil end
  return {
    type = stat.type,
    size = stat.size,
    mtime_sec = stat.mtime.sec,
    mtime_nsec = stat.mtime.nsec,
  }
end

local function stat_matches(path, expected)
  local current = stat_snapshot(path)
  return current
    and current.type == expected.type
    and current.size == expected.size
    and current.mtime_sec == expected.mtime_sec
    and current.mtime_nsec == expected.mtime_nsec
end

local function resource_buffers(path)
  local buffers = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= '' then
        local normalized = normalize_path(name)
        if normalized and (normalized == path or normalized:sub(1, #path + 1) == path .. '/') then
          buffers[#buffers + 1] = {
            bufnr = bufnr,
            path = normalized,
            changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
            modified = vim.bo[bufnr].modified,
          }
        end
      end
    end
  end
  return buffers
end

local function is_empty_buffer(bufnr)
  return vim.api.nvim_buf_line_count(bufnr) == 1
    and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == ''
end

local function target_buffers(path)
  local buffers = resource_buffers(path)
  for _, state in ipairs(buffers) do
    if state.path ~= path or state.modified or not is_empty_buffer(state.bufnr) then
      return nil
    end
  end
  return buffers
end

local function buffers_match(buffers)
  for _, state in ipairs(buffers) do
    if not vim.api.nvim_buf_is_valid(state.bufnr)
        or normalize_path(vim.api.nvim_buf_get_name(state.bufnr)) ~= state.path
        or vim.api.nvim_buf_get_changedtick(state.bufnr) ~= state.changedtick
        or vim.bo[state.bufnr].modified ~= state.modified then
      return false
    end
  end
  return true
end

local function preview(params)
  purge_expired()
  local old_path = normalize_path(params.oldUri)
  local new_path = normalize_path(params.newUri)
  if not old_path or not new_path then
    return error_result('invalid_resource_path', 'oldUri and newUri must be absolute file paths or file URIs')
  end
  if old_path == new_path then
    return error_result('resource_path_unchanged', 'oldUri and newUri must be different')
  end
  local root = shared_root(old_path, new_path)
  if not root then
    return error_result('resource_outside_workspace', 'Both resource paths must remain inside one workspace root')
  end
  local old_stat = stat_snapshot(old_path)
  if not old_stat then return error_result('resource_not_found', 'Source resource does not exist') end
  if vim.uv.fs_lstat(new_path) then return error_result('resource_target_exists', 'Target resource already exists') end

  local buffers = resource_buffers(old_path)
  for _, state in ipairs(buffers) do
    if state.modified then
      return error_result('resource_buffer_modified', 'Save modified buffers under the source path before preview')
    end
  end
  local ghosts = target_buffers(new_path)
  if not ghosts then
    return error_result(
      'resource_target_buffer_conflict',
      'Target path is already used by a modified, non-empty, or nested buffer'
    )
  end

  local timeout_ms = tonumber(params.timeoutMs) or 5000
  local edits, clients, lsp_error = FileOperations.will_rename_sync(old_path, new_path, timeout_ms)
  if not edits then return { error = lsp_error } end

  local workspace, workspace_error = WorkspaceEdit.prepare(edits)
  if not workspace then return { error = workspace_error } end
  local id = vim.fn.sha256(table.concat({
    tostring(vim.fn.getpid()), tostring(vim.uv.hrtime()), old_path, new_path,
  }, ':')):sub(1, 24)
  local expires_at = os.time() + ttl_seconds
  transactions[id] = {
    old_path = old_path,
    new_path = new_path,
    root = root,
    old_stat = old_stat,
    buffers = buffers,
    target_ghosts = ghosts,
    clients = clients,
    workspace = workspace,
    expires_at = expires_at,
  }
  return {
    operation = 'rename_resource_preview',
    resourceRenameId = id,
    oldUri = Normalize.wire_path(old_path),
    newUri = Normalize.wire_path(new_path),
    resourceType = old_stat.type,
    clients = clients,
    filesChanged = workspace.files_changed,
    editsCount = workspace.edits_count,
    changes = workspace.changes,
    expiresAt = expires_at,
  }
end

local function notify_did_rename(transaction)
  FileOperations.notify_did_rename(transaction.old_path, transaction.new_path)
end

local function sync_resource_buffers(transaction)
  for _, state in ipairs(transaction.buffers) do
    local suffix = state.path:sub(#transaction.old_path + 1)
    local target = transaction.new_path .. suffix
    vim.api.nvim_buf_set_name(state.bufnr, target)
    pcall(vim.api.nvim_buf_call, state.bufnr, function()
      vim.cmd('silent! doautocmd BufFilePost')
    end)
  end
end

local function apply(params)
  purge_expired()
  local id = params.resourceRenameId
  if type(id) ~= 'string' or id == '' then
    return error_result('invalid_resource_rename_id', 'resourceRenameId is required for rename_resource_apply')
  end
  local transaction = transactions[id]
  if not transaction then
    return error_result('resource_rename_not_found', 'Resource rename preview not found or already applied')
  end
  if os.time() > transaction.expires_at then
    transactions[id] = nil
    return error_result('resource_rename_expired', 'Resource rename preview expired; request a new preview')
  end
  if not stat_matches(transaction.old_path, transaction.old_stat)
      or vim.uv.fs_lstat(transaction.new_path)
      or not buffers_match(transaction.buffers)
      or not buffers_match(transaction.target_ghosts) then
    transactions[id] = nil
    return error_result('resource_rename_stale', 'Source, target, or loaded buffer changed after preview')
  end

  local workspace_applied, workspace_error = WorkspaceEdit.apply(transaction.workspace)
  if not workspace_applied then
    transactions[id] = nil
    return { error = workspace_error }
  end

  local renamed, rename_error = pcall(Fs.rename, transaction.old_path, transaction.new_path)
  if not renamed then
    WorkspaceEdit.restore(transaction.workspace)
    transactions[id] = nil
    return error_result('resource_rename_failed', tostring(rename_error))
  end

  for _, state in ipairs(transaction.target_ghosts) do
    pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
  end
  sync_resource_buffers(transaction)
  Fs.sync_buffers(transaction.old_path, transaction.new_path)
  notify_did_rename(transaction)
  transactions[id] = nil
  return {
    operation = 'rename_resource_apply',
    resourceRenameId = id,
    applied = true,
    saved = true,
    oldUri = Normalize.wire_path(transaction.old_path),
    newUri = Normalize.wire_path(transaction.new_path),
    resourceType = transaction.old_stat.type,
    filesChanged = transaction.workspace.files_changed,
    editsCount = transaction.workspace.edits_count,
  }
end

---执行 workspace 工具的资源重命名预览或应用阶段
---@param params table MCP workspace 工具参数
---@return table result
function M.request(params)
  if params.operation == 'rename_resource_preview' then return preview(params) end
  if params.operation == 'rename_resource_apply' then return apply(params) end
  return error_result('unsupported_operation', 'Unsupported workspace operation: ' .. tostring(params.operation))
end

return M
