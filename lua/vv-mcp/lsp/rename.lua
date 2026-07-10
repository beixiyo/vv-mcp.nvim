local Normalize = require('vv-mcp.lsp.normalize')

local M = {}
local transactions = {}
local ttl_seconds = 300

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

local function position_params(context)
  return {
    textDocument = { uri = vim.uri_from_bufnr(context.bufnr) },
    position = {
      line = context.params.line - 1,
      character = context.params.character - 1,
    },
  }
end

local function find_loaded_buffer(uri)
  local path = vim.uri_to_fname(uri)
  local resolved = vim.fn.resolve(path)
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
    if change.textDocument and change.edits then
      entries[#entries + 1] = { uri = change.textDocument.uri, edits = change.edits }
    end
  end
  return entries
end

local function has_resource_operations(edit)
  for _, change in ipairs(edit.documentChanges or {}) do
    if not change.textDocument then return true end
  end
  return false
end

local function snapshot(edit)
  local states = {}
  local summary = {}
  local edits_count = 0
  for _, entry in ipairs(edit_entries(edit)) do
    states[entry.uri] = file_state(entry.uri)
    local path = Normalize.wire_path(vim.uri_to_fname(entry.uri))
    summary[path] = summary[path] or {}
    for _, text_edit in ipairs(entry.edits) do
      local range = text_edit.range or text_edit.replace or text_edit.insert
      if range then
        summary[path][#summary[path] + 1] = {
          start = { line = range.start.line + 1, character = range.start.character + 1 },
          ['end'] = { line = range['end'].line + 1, character = range['end'].character + 1 },
        }
        edits_count = edits_count + 1
      end
    end
  end
  return states, summary, edits_count
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

local function clear_document_versions(edit)
  for _, change in ipairs(edit.documentChanges or {}) do
    if change.textDocument then change.textDocument.version = vim.NIL end
  end
end

local function all_targets_changed(transaction)
  for _, state in pairs(transaction.states) do
    local bufnr = find_loaded_buffer(state.uri)
    if bufnr < 0 then return false end
    if state.bufnr and vim.api.nvim_buf_get_changedtick(bufnr) == state.changedtick then
      return false
    end
    if not state.bufnr and not vim.bo[bufnr].modified then return false end
  end
  return true
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
    if restore_disk and state.disk_content then
      write_file(state.path, state.disk_content)
    end
  end
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

local function prepare(context, operation)
  local results = {}
  for _, client in ipairs(context.clients) do
    if client:supports_method(operation.method, context.bufnr) then
      local response, error = client:request_sync(
        operation.method,
        position_params(context),
        context.timeout_ms,
        context.bufnr
      )
      results[#results + 1] = {
        client = client.name,
        result = response and Normalize.result(response.result) or nil,
        error = error and tostring(error) or nil,
      }
    end
  end
  return { operation = operation.name, path = Normalize.wire_path(context.path), results = results }
end

local function preview(context, operation)
  local now = os.time()
  for rename_id, transaction in pairs(transactions) do
    if now > transaction.expires_at then transactions[rename_id] = nil end
  end
  for _, client in ipairs(context.clients) do
    if client:supports_method(operation.method, context.bufnr) then
      local params = position_params(context)
      params.newName = context.params.newName
      local response, error = client:request_sync(
        operation.method,
        params,
        context.timeout_ms,
        context.bufnr
      )
      if response and response.result then
        if has_resource_operations(response.result) then
          return {
            error = {
              code = 'rename_resource_operations_unsupported',
              message = 'Rename preview contains file resource operations, which are not supported yet',
            },
          }
        end
        local states, changes, edits_count = snapshot(response.result)
        clear_document_versions(response.result)
        local rename_id = vim.fn.sha256(table.concat({
          tostring(vim.fn.getpid()), tostring(vim.uv.hrtime()), context.params.newName,
        }, ':')):sub(1, 24)
        local expires_at = os.time() + ttl_seconds
        transactions[rename_id] = {
          edit = response.result,
          encoding = client.offset_encoding,
          states = states,
          expires_at = expires_at,
          files_changed = vim.tbl_count(changes),
          edits_count = edits_count,
        }
        return {
          operation = operation.name,
          renameId = rename_id,
          client = client.name,
          newName = context.params.newName,
          filesChanged = vim.tbl_count(changes),
          editsCount = edits_count,
          expiresAt = expires_at,
          changes = changes,
        }
      end
      if error then
        return { error = { code = 'rename_failed', message = tostring(error), client = client.name } }
      end
    end
  end
  return { error = { code = 'capability_unsupported', message = 'No attached LSP client supports rename' } }
end

local function apply(context)
  local rename_id = context.params.renameId
  local transaction = transactions[rename_id]
  if not transaction then
    return { error = { code = 'rename_not_found', message = 'Rename preview not found or already applied' } }
  end
  if os.time() > transaction.expires_at then
    transactions[rename_id] = nil
    return { error = { code = 'rename_expired', message = 'Rename preview expired; request a new preview' } }
  end
  for _, state in pairs(transaction.states) do
    if not state_matches(state) then
      transactions[rename_id] = nil
      return { error = { code = 'rename_stale', message = 'A target buffer or file changed after preview' } }
    end
  end

  local ok, error = pcall(vim.lsp.util.apply_workspace_edit, transaction.edit, transaction.encoding)
  if not ok then
    rollback(transaction)
    transactions[rename_id] = nil
    return { error = { code = 'rename_apply_failed', message = tostring(error) } }
  end
  if not all_targets_changed(transaction) then
    rollback(transaction)
    transactions[rename_id] = nil
    return {
      error = {
        code = 'rename_partial_apply',
        message = 'Not every target edit was applied; all changed buffers were rolled back',
      },
    }
  end
  local saved, save_error = save_targets(transaction)
  if not saved then
    rollback(transaction, true)
    transactions[rename_id] = nil
    return { error = { code = 'rename_save_failed', message = save_error } }
  end
  transactions[rename_id] = nil
  return {
    operation = 'rename_apply',
    renameId = rename_id,
    applied = true,
    saved = true,
    filesChanged = transaction.files_changed,
    editsCount = transaction.edits_count,
  }
end

function M.request(context, operation)
  if operation.name == 'prepare_rename' then return prepare(context, operation) end
  if operation.name == 'rename_preview' then return preview(context, operation) end
  return apply(context)
end

return M
