---管理跨文件重命名的能力预检、无副作用预览与单次安全应用事务
---
---预览时保存目标 buffer 与磁盘快照；应用前检查内容是否过期，应用或保存失败时
---回滚所有已变更目标，避免跨文件重命名只完成一部分
local Normalize = require('vv-mcp.lsp.normalize')
local WorkspaceEdit = require('vv-utils.lsp.workspace_edit')

local M = {}
local transactions = {}
---重命名预览只在当前 Neovim 进程内保留五分钟
local ttl_seconds = 300

local function position_params(context)
  return {
    textDocument = { uri = vim.uri_from_bufnr(context.bufnr) },
    position = {
      line = context.params.line - 1,
      character = context.params.character - 1,
    },
  }
end

local rename_error_codes = {
  resource_operations_unsupported = 'rename_resource_operations_unsupported',
  workspace_edit_stale = 'rename_stale',
  workspace_edit_apply_failed = 'rename_apply_failed',
  workspace_edit_partial_apply = 'rename_partial_apply',
  workspace_edit_save_failed = 'rename_save_failed',
}

local function rename_error(error)
  return {
    code = rename_error_codes[error.code] or error.code,
    message = error.message,
  }
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
        local workspace, workspace_error = WorkspaceEdit.prepare({ {
          edit = response.result,
          encoding = client.offset_encoding or 'utf-16',
        } })
        if not workspace then return { error = rename_error(workspace_error) } end
        local rename_id = vim.fn.sha256(table.concat({
          tostring(vim.fn.getpid()), tostring(vim.uv.hrtime()), context.params.newName,
        }, ':')):sub(1, 24)
        local expires_at = os.time() + ttl_seconds
        transactions[rename_id] = {
          workspace = workspace,
          expires_at = expires_at,
        }
        return {
          operation = operation.name,
          renameId = rename_id,
          client = client.name,
          newName = context.params.newName,
          filesChanged = workspace.files_changed,
          editsCount = workspace.edits_count,
          expiresAt = expires_at,
          changes = workspace.changes,
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
  local applied, apply_error = WorkspaceEdit.apply(transaction.workspace)
  transactions[rename_id] = nil
  if not applied then return { error = rename_error(apply_error) } end
  return {
    operation = 'rename_apply',
    renameId = rename_id,
    applied = true,
    saved = true,
    filesChanged = transaction.workspace.files_changed,
    editsCount = transaction.workspace.edits_count,
  }
end

---执行重命名流程中的 prepare、preview 或 apply 阶段
---@param context VVMcpLspContext 请求上下文
---@param operation VVMcpLspOperation 操作定义
---@return table result
function M.request(context, operation)
  if operation.name == 'prepare_rename' then return prepare(context, operation) end
  if operation.name == 'rename_preview' then return preview(context, operation) end
  return apply(context)
end

return M
