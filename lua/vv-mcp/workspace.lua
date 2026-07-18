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

-- 纯字符串规范化，得到「逻辑路径」——对外 wire 协议与事务标识都用它，行为对用户稳定
local function normalize_path(value)
  if type(value) ~= 'string' or value == '' then return nil end
  local path = value:match('^file://') and vim.uri_to_fname(value) or value
  local absolute = path:sub(1, 1) == '/' or path:match('^%a:[/\\]') ~= nil
  if not absolute then return nil end
  return vim.fs.normalize(path)
end

-- 解析路径的真实位置：只规范化父目录（跟随中间 symlink），保留最终组件本身
-- 与 rename(2) 语义一致——中间 symlink 跟随、最终组件不跟随（操作链接本身）
-- 用于工作区边界判定与 buffer 身份比对，堵住经内部目录 symlink 越出 workspace 的绕过
local function real_path(path)
  return vim.fs.joinpath(Fs.realpath(vim.fs.dirname(path)), vim.fs.basename(path))
end

local function is_inside(path, root)
  local real = real_path(path)
  -- root 自身可能就是 symlink，需完整解析（含最终组件），故用 Fs.realpath 而非 real_path
  local base = Fs.realpath(root):gsub('/+$', '')
  return real == base or real:sub(1, #base + 1) == base .. '/'
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
  -- dev/ino 锁定 inode 身份：仅凭 type/size/mtime，被同尺寸同时间戳的文件原位替换仍会蒙混过关
  return {
    type = stat.type,
    size = stat.size,
    mtime_sec = stat.mtime.sec,
    mtime_nsec = stat.mtime.nsec,
    dev = stat.dev,
    ino = stat.ino,
  }
end

local function stat_matches(path, expected)
  local current = stat_snapshot(path)
  return current
    and current.type == expected.type
    and current.size == expected.size
    and current.mtime_sec == expected.mtime_sec
    and current.mtime_nsec == expected.mtime_nsec
    and current.dev == expected.dev
    and current.ino == expected.ino
end

-- 按真实路径匹配：Neovim 打开逻辑路径后 buffer 名是解析后的真实路径，
-- 逻辑 path 与真实 buffer 名直接比对会漏命中，导致已改 buffer 的保护与同步失效
local function resource_buffers(path)
  local prefix = real_path(path)
  local buffers = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= '' then
        local normalized = normalize_path(name)
        if normalized then
          local real = real_path(normalized)
          if real == prefix or real:sub(1, #prefix + 1) == prefix .. '/' then
            buffers[#buffers + 1] = {
              bufnr = bufnr,
              path = real,
              changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
              modified = vim.bo[bufnr].modified,
            }
          end
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
  local prefix = real_path(path)
  for _, state in ipairs(buffers) do
    if state.path ~= prefix or state.modified or not is_empty_buffer(state.bufnr) then
      return nil
    end
  end
  return buffers
end

local function buffers_match(buffers)
  for _, state in ipairs(buffers) do
    if not vim.api.nvim_buf_is_valid(state.bufnr) then return false end
    local normalized = normalize_path(vim.api.nvim_buf_get_name(state.bufnr))
    if not normalized
        or real_path(normalized) ~= state.path
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
    real_old = real_path(old_path),
    real_new = real_path(new_path),
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
  -- buffer 名与后缀都以真实路径为准（见 resource_buffers），renamed 后指向真实新位置
  for _, state in ipairs(transaction.buffers) do
    local suffix = state.path:sub(#transaction.real_old + 1)
    local target = transaction.real_new .. suffix
    vim.api.nvim_buf_set_name(state.bufnr, target)
    pcall(vim.api.nvim_buf_call, state.bufnr, function()
      vim.cmd('silent! doautocmd BufFilePost')
    end)
  end
end

-- preview→apply（TTL 300 秒）窗口内，中间目录可能被换成越界 symlink：preview 存下的
-- real_old/real_new/root 已固化真实边界，apply 前后复检确保 old/new 的真实解析与所在 root 未变。
-- FS 未变时 real_path/shared_root 幂等，正常 apply 不会被误判（含目标父目录尚不存在的场景）
local function boundary_intact(transaction)
  return real_path(transaction.old_path) == transaction.real_old
    and real_path(transaction.new_path) == transaction.real_new
    and shared_root(transaction.old_path, transaction.new_path) == transaction.root
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
      or not buffers_match(transaction.target_ghosts)
      or not boundary_intact(transaction) then
    transactions[id] = nil
    return error_result('resource_rename_stale', 'Source, target, or loaded buffer changed after preview')
  end

  local workspace_applied, workspace_error = WorkspaceEdit.apply(transaction.workspace)
  if not workspace_applied then
    transactions[id] = nil
    return { error = workspace_error }
  end

  -- WorkspaceEdit.apply 与 Fs.rename 之间仍有可观察窗口：写入后、移动前再复检真实边界，
  -- 越界则回滚已应用的 import 编辑，避免留下「已改引用、文件未移动」的半应用状态
  if not boundary_intact(transaction) then
    WorkspaceEdit.restore(transaction.workspace)
    transactions[id] = nil
    return error_result('resource_rename_stale', 'Source, target, or loaded buffer changed after preview')
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
