---将多个 LSP WorkspaceEdit 规范化、去重并作为一个安全事务应用
---
---所有客户端坐标先转换为 UTF-8 字节坐标，再合并为一次编辑，避免多 LSP
---依次应用时产生坐标漂移。应用前后都会检查 buffer 与磁盘状态，失败则回滚
local Normalize = require('vv-mcp.lsp.normalize')

local M = {}

local function read_file(path)
  local file = io.open(path, 'rb')
  if not file then return nil end
  local content = file:read('*a')
  file:close()
  return content
end

local function write_file(path, content)
  local file, error = io.open(path, 'wb')
  if not file then return false, error end
  local ok, write_error = file:write(content)
  file:close()
  return ok ~= nil, write_error
end

local function find_loaded_buffer(uri)
  local resolved = vim.fn.resolve(vim.uri_to_fname(uri))
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(candidate)
        and vim.fn.resolve(vim.api.nvim_buf_get_name(candidate)) == resolved then
      return candidate
    end
  end
  return -1
end

local function file_state(uri)
  local path = vim.uri_to_fname(uri)
  local bufnr = find_loaded_buffer(uri)
  local stat = vim.uv.fs_stat(path)
  if bufnr >= 0 and vim.api.nvim_buf_is_loaded(bufnr) then
    return {
      uri = uri,
      path = path,
      bufnr = bufnr,
      changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
      lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
      modified = vim.bo[bufnr].modified,
      disk_content = read_file(path),
      size = stat and stat.size or nil,
      mtime_sec = stat and stat.mtime.sec or nil,
      mtime_nsec = stat and stat.mtime.nsec or nil,
    }
  end
  return stat and {
    uri = uri,
    path = path,
    size = stat.size,
    mtime_sec = stat.mtime.sec,
    mtime_nsec = stat.mtime.nsec,
    disk_content = read_file(path),
  } or { uri = uri, path = path, missing = true }
end

local function edit_entries(edit)
  local entries = {}
  for uri, edits in pairs(edit.changes or {}) do
    entries[#entries + 1] = { uri = uri, edits = edits }
  end
  for _, change in ipairs(edit.documentChanges or {}) do
    if not change.textDocument then return nil end
    if change.edits then
      entries[#entries + 1] = { uri = change.textDocument.uri, edits = change.edits }
      change.textDocument.version = vim.NIL
    end
  end
  return entries
end

local function compare_position(left, right)
  if left.line ~= right.line then return left.line < right.line and -1 or 1 end
  if left.character == right.character then return 0 end
  return left.character < right.character and -1 or 1
end

local function ranges_overlap(left, right)
  local same_start = compare_position(left.start, right.start) == 0
  local left_empty = compare_position(left.start, left['end']) == 0
  local right_empty = compare_position(right.start, right['end']) == 0
  if same_start and (left_empty or right_empty) then return true end
  return compare_position(left['end'], right.start) > 0
    and compare_position(right['end'], left.start) > 0
end

local function snapshot_lines(state)
  if state.lines then return state.lines end
  return vim.split(state.disk_content or '', '\n', { plain = true })
end

local function normalize_range(state, range, encoding)
  local lines = snapshot_lines(state)
  local function position(value)
    local line = lines[value.line + 1] or ''
    local ok, character = pcall(vim.str_byteindex, line, encoding, value.character, false)
    if not ok then return nil end
    return { line = value.line, character = character }
  end
  local start = position(range.start)
  local finish = position(range['end'])
  if not start or not finish then return nil end
  return { start = start, ['end'] = finish }
end

local function state_matches(state)
  local stat = vim.uv.fs_stat(state.path)
  local disk_matches = stat
    and stat.size == state.size
    and stat.mtime.sec == state.mtime_sec
    and stat.mtime.nsec == state.mtime_nsec
  if state.bufnr then
    return vim.api.nvim_buf_is_valid(state.bufnr)
      and vim.api.nvim_buf_get_changedtick(state.bufnr) == state.changedtick
      and disk_matches
  end
  if state.missing then return stat == nil end
  return disk_matches
end

local function rollback(transaction, restore_disk)
  for _, state in pairs(transaction.states) do
    local bufnr = find_loaded_buffer(state.uri)
    if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
      vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, state.lines)
      vim.bo[state.bufnr].modified = state.modified
    elseif bufnr >= 0 and vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
    if restore_disk and state.disk_content then write_file(state.path, state.disk_content) end
  end
end

local function all_targets_changed(transaction)
  for _, state in pairs(transaction.states) do
    local bufnr = find_loaded_buffer(state.uri)
    if bufnr < 0 then return false end
    if state.bufnr and vim.api.nvim_buf_get_changedtick(bufnr) == state.changedtick then return false end
    if not state.bufnr and not vim.bo[bufnr].modified then return false end
  end
  return true
end

local function save_targets(transaction)
  for _, state in pairs(transaction.states) do
    local bufnr = find_loaded_buffer(state.uri)
    if bufnr < 0 or not vim.api.nvim_buf_is_valid(bufnr) then
      return false, 'Target buffer is unavailable: ' .. state.path
    end
    local ok, error = pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd('silent noautocmd write')
    end)
    if not ok then return false, tostring(error) end
    if vim.bo[bufnr].modified then
      return false, 'Target buffer remains modified after write: ' .. state.path
    end
  end
  return true
end

---准备无副作用的 WorkspaceEdit 事务
---@param edits { edit: table, encoding: string }[] 各客户端返回的编辑及其坐标编码
---@return table? transaction 已规范化、可安全应用的事务
---@return table? error
function M.prepare(edits)
  local states = {}
  local changes = {}
  local merged = { changes = {} }
  local ranges_by_uri = {}
  local seen_edits = {}
  local edits_count = 0
  for _, item in ipairs(edits) do
    local entries = edit_entries(item.edit)
    if not entries then
      return nil, {
        code = 'resource_operations_unsupported',
        message = 'Workspace edit contains file resource operations, which are not supported yet',
      }
    end
    for _, entry in ipairs(entries) do
      local encoding = item.encoding or 'utf-16'
      states[entry.uri] = states[entry.uri] or file_state(entry.uri)
      merged.changes[entry.uri] = merged.changes[entry.uri] or {}
      local path = Normalize.wire_path(vim.uri_to_fname(entry.uri))
      changes[path] = changes[path] or {}
      ranges_by_uri[entry.uri] = ranges_by_uri[entry.uri] or {}
      for _, text_edit in ipairs(entry.edits) do
        local range = text_edit.range or text_edit.replace or text_edit.insert
        if range then
          local normalized_range = normalize_range(states[entry.uri], range, encoding)
          if not normalized_range then
            return nil, {
              code = 'workspace_edit_invalid_range',
              message = 'Workspace edit contains an invalid range for ' .. path,
            }
          end
          local fingerprint = vim.fn.sha256(vim.json.encode({
            uri = entry.uri,
            range = normalized_range,
            newText = text_edit.newText,
          }))
          if not seen_edits[fingerprint] then
            for _, existing in ipairs(ranges_by_uri[entry.uri]) do
              if ranges_overlap(existing, normalized_range) then
                return nil, {
                  code = 'workspace_edit_conflict',
                  message = 'Workspace edit contains overlapping changes for ' .. path,
                }
              end
            end
            seen_edits[fingerprint] = true
            ranges_by_uri[entry.uri][#ranges_by_uri[entry.uri] + 1] = normalized_range
            local normalized_edit = vim.deepcopy(text_edit)
            normalized_edit.range = normalized_range
            normalized_edit.insert = nil
            normalized_edit.replace = nil
            merged.changes[entry.uri][#merged.changes[entry.uri] + 1] = normalized_edit
            changes[path][#changes[path] + 1] = {
              start = { line = range.start.line + 1, character = range.start.character + 1 },
              ['end'] = { line = range['end'].line + 1, character = range['end'].character + 1 },
            }
            edits_count = edits_count + 1
          end
        end
      end
    end
  end
  return {
    edits = { { edit = merged, encoding = 'utf-8' } },
    states = states,
    changes = changes,
    files_changed = vim.tbl_count(changes),
    edits_count = edits_count,
  }
end

---原子应用事务并写入所有目标文件，任何阶段失败都会尝试回滚
---@param transaction table M.prepare 返回的事务
---@return boolean ok
---@return table? error
function M.apply(transaction)
  for _, state in pairs(transaction.states) do
    if not state_matches(state) then
      return false, { code = 'workspace_edit_stale', message = 'A target buffer or file changed after preview' }
    end
  end
  for _, item in ipairs(transaction.edits) do
    local ok, error = pcall(vim.lsp.util.apply_workspace_edit, item.edit, item.encoding)
    if not ok then
      rollback(transaction)
      return false, { code = 'workspace_edit_apply_failed', message = tostring(error) }
    end
  end
  if not all_targets_changed(transaction) then
    rollback(transaction)
    return false, {
      code = 'workspace_edit_partial_apply',
      message = 'Not every target edit was applied; all changed buffers were rolled back',
    }
  end
  local saved, save_error = save_targets(transaction)
  if not saved then
    rollback(transaction, true)
    return false, { code = 'workspace_edit_save_failed', message = save_error }
  end
  return true
end

---恢复 WorkspaceEdit 事务预览时的 buffer 与磁盘内容
---供文件系统操作在后续阶段失败时补偿已经保存的文本编辑
---@param transaction table M.prepare 返回的事务
function M.restore(transaction)
  rollback(transaction, true)
end

return M
