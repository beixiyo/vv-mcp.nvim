---管理 Code Action 的查询、无副作用预览和单次安全应用事务
local Normalize = require('vv-mcp.lsp.normalize')
local SharedCodeActions = require('vv-utils.lsp.code_actions')
local WorkspaceEdit = require('vv-utils.lsp.workspace_edit')

local M = {}
local transactions = {}
---预览事务只保存在当前 Neovim 进程中，超时或应用后立即失效
local ttl_seconds = 300

local function action_id(seed)
  return vim.fn.sha256(table.concat({
    tostring(vim.fn.getpid()), tostring(vim.uv.hrtime()), seed,
  }, ':')):sub(1, 24)
end

local function purge_expired()
  local now = os.time()
  for id, transaction in pairs(transactions) do
    if now > transaction.expires_at then transactions[id] = nil end
  end
end

local function lsp_diagnostics(bufnr, line, namespace)
  local diagnostics = {}
  local options = {}
  if type(line) == 'number' then options.lnum = line end
  if type(namespace) == 'number' then options.namespace = namespace end
  for _, diagnostic in ipairs(vim.diagnostic.get(bufnr, options)) do
    if diagnostic.user_data and diagnostic.user_data.lsp then
      diagnostics[#diagnostics + 1] = diagnostic.user_data.lsp
    end
  end
  return diagnostics
end

local function request_params(context, whole_file)
  local last_line = math.max(vim.api.nvim_buf_line_count(context.bufnr) - 1, 0)
  local position = {
    line = type(context.params.line) == 'number' and context.params.line - 1 or 0,
    character = type(context.params.character) == 'number' and context.params.character - 1 or 0,
  }

  return {
    textDocument = { uri = vim.uri_from_bufnr(context.bufnr) },
    range = whole_file and {
      start = { line = 0, character = 0 },
      ['end'] = { line = last_line, character = 0 },
    } or { start = position, ['end'] = position },

    context = {
      diagnostics = lsp_diagnostics(context.bufnr, whole_file and nil or position.line),
      only = whole_file and { 'quickfix' }
        or (type(context.params.actionKind) == 'string' and { context.params.actionKind } or nil),
    },
  }
end

local function resolve_action(transaction, context)
  local action = transaction.action
  if action.disabled then
    return nil, {
      code = 'code_action_disabled',
      message = action.disabled.reason or 'Code action is disabled',
    }
  end

  local client = vim.lsp.get_client_by_id(transaction.client_id)
  if not client then
    return nil, { code = 'code_action_client_gone', message = 'The LSP client is no longer active' }
  end

  if not action.edit and action.data and client:supports_method('codeAction/resolve', context.bufnr) then
    local response, error = client:request_sync(
      'codeAction/resolve', action, context.timeout_ms, context.bufnr
    )
    if error then
      return nil, { code = 'code_action_resolve_failed', message = tostring(error) }
    end
    action = response and response.result or action
  end

  if action.command then
    return nil, {
      code = 'code_action_command_unsupported',
      message = 'Command-backed code actions are not supported yet',
    }
  end

  if not action.edit then
    return nil, { code = 'code_action_no_edit', message = 'Code action did not return a workspace edit' }
  end
  return action, client
end

local function list_actions(context, operation)
  purge_expired()
  local items = {}
  local errors = {}
  local params = request_params(context, false)

  for _, client in ipairs(context.clients) do
    if client:supports_method(operation.method, context.bufnr) then
      local response, error = client:request_sync(
        operation.method, params, context.timeout_ms, context.bufnr
      )

      if error then
        errors[client.name] = tostring(error)
      end

      for _, action in ipairs(response and response.result or {}) do
        local temporary = { action = action, client_id = client.id }
        local resolved, resolve_error = resolve_action(temporary, context)

        if resolved then
          local workspace, workspace_error = WorkspaceEdit.prepare({
            { edit = resolved.edit, encoding = client.offset_encoding or 'utf-16' },
          })

          if workspace and workspace.edits_count > 0 then
            local id = action_id(resolved.title or client.name)
            local expires_at = os.time() + ttl_seconds

            transactions[id] = {
              action = resolved,
              client_id = client.id,
              workspace = workspace,
              expires_at = expires_at,
            }
            items[#items + 1] = {
              actionId = id,
              client = client.name,
              title = resolved.title or 'Untitled action',
              kind = resolved.kind,
              preferred = resolved.isPreferred == true,
              expiresAt = expires_at,
            }
          elseif workspace_error then
            errors[client.name] = workspace_error.message
          end
        elseif resolve_error and resolve_error.code ~= 'code_action_command_unsupported' then
          errors[client.name] = resolve_error.message
        end
      end
    end
  end

  return {
    operation = operation.name,
    path = Normalize.wire_path(context.path),
    items = items,
    errors = errors,
  }
end

local function preview(context)
  purge_expired()
  local id = context.params.actionId
  local transaction = transactions[id]

  if not transaction then
    return { error = { code = 'code_action_not_found', message = 'Code action not found or expired' } }
  end

  local fresh, stale_error = WorkspaceEdit.validate(transaction.workspace)
  if not fresh then
    transactions[id] = nil
    return { error = stale_error }
  end

  return {
    operation = 'code_action_preview',
    actionId = id,
    title = transaction.action.title,
    kind = transaction.action.kind,
    filesChanged = transaction.workspace.files_changed,
    editsCount = transaction.workspace.edits_count,
    expiresAt = transaction.expires_at,
    changes = transaction.workspace.changes,
  }
end

local function document_fix_preview(context, operation)
  purge_expired()
  local collected, error = SharedCodeActions.collect_document_fixes({
    bufnr = context.bufnr,
    line = context.params.line,
    character = context.params.character,
    timeout_ms = context.timeout_ms,
    prefer_fix_all = true,
  })
  if not collected then return { error = error } end
  local workspace_transaction = collected.workspace

  local id = action_id(operation.name)
  local expires_at = os.time() + ttl_seconds
  transactions[id] = {
    workspace = workspace_transaction,
    expires_at = expires_at,
  }

  return {
    operation = operation.name,
    actionId = id,
    titles = collected.titles,
    actionsCount = collected.actions_count,
    clients = collected.clients,
    filesChanged = workspace_transaction.files_changed,
    editsCount = workspace_transaction.edits_count,
    expiresAt = expires_at,
    changes = workspace_transaction.changes,
  }
end

local function apply(context, operation_name)
  purge_expired()
  local id = context.params.actionId
  local transaction = transactions[id]

  if not transaction or not transaction.workspace then
    return {
      error = {
        code = 'code_action_not_previewed',
        message = 'Code action must be previewed before apply',
      },
    }
  end

  local ok, error = WorkspaceEdit.apply(transaction.workspace)
  transactions[id] = nil

  if not ok then return { error = error } end

  return {
    operation = operation_name or 'code_action_apply',
    actionId = id,
    applied = true,
    saved = true,
    filesChanged = transaction.workspace.files_changed,
    editsCount = transaction.workspace.edits_count,
  }
end

local function fix_document(context, operation)
  local preview = document_fix_preview(context, operation)
  if preview.error then return preview end

  local previous_id = context.params.actionId
  context.params.actionId = preview.actionId
  local result = apply(context, 'fix_document')
  context.params.actionId = previous_id
  if result.error then return result end

  result.changed = true
  result.clients = preview.clients
  result.titles = preview.titles
  result.actionsCount = preview.actionsCount
  return result
end

---执行 Code Action 操作并维护 preview -> apply 的事务约束
---@param context VVMcpLspContext 请求上下文
---@param operation VVMcpLspOperation 操作定义
---@return table result
function M.request(context, operation)
  if operation.name == 'code_actions' then return list_actions(context, operation) end
  if operation.name == 'code_action_preview' then return preview(context) end
  if operation.name == 'fix_document_preview' then return document_fix_preview(context, operation) end
  if operation.name == 'fix_document' then return fix_document(context, operation) end
  return apply(context)
end

return M
