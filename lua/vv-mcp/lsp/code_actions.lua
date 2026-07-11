---管理 Code Action 的查询、无副作用预览和单次安全应用事务
local Normalize = require('vv-mcp.lsp.normalize')
local WorkspaceEdit = require('vv-mcp.lsp.workspace_edit')

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

local function diagnostic_params(context, diagnostic)
  local lsp_diagnostic = diagnostic.user_data and diagnostic.user_data.lsp
  local range = lsp_diagnostic and lsp_diagnostic.range or {
    start = { line = diagnostic.lnum, character = diagnostic.col },
    ['end'] = {
      line = diagnostic.end_lnum or diagnostic.lnum,
      character = diagnostic.end_col or diagnostic.col,
    },
  }
  return {
    textDocument = { uri = vim.uri_from_bufnr(context.bufnr) },
    range = range,
    context = {
      diagnostics = lsp_diagnostic and { lsp_diagnostic } or {},
      only = { 'quickfix' },
    },
  }
end

local function client_diagnostics(context, client)
  local diagnostics = {}
  local seen = {}
  local marker = ('lsp.%s.%d'):format(client.name, client.id)
  local namespaces = {
    [vim.lsp.diagnostic.get_namespace(client.id)] = true,
  }
  for name, namespace in pairs(vim.api.nvim_get_namespaces()) do
    if name:find(marker, 1, true) then namespaces[namespace] = true end
  end
  for namespace in pairs(namespaces) do
    for _, diagnostic in ipairs(vim.diagnostic.get(context.bufnr, { namespace = namespace })) do
      local lsp_diagnostic = diagnostic.user_data and diagnostic.user_data.lsp
      if lsp_diagnostic then
        local fingerprint = vim.fn.sha256(vim.json.encode(lsp_diagnostic))
        if not seen[fingerprint] then
          seen[fingerprint] = true
          diagnostics[#diagnostics + 1] = diagnostic
        end
      end
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
        local id = action_id(action.title or action.command or client.name)
        local expires_at = os.time() + ttl_seconds
        transactions[id] = {
          action = action,
          client_id = client.id,
          expires_at = expires_at,
        }
        items[#items + 1] = {
          actionId = id,
          client = client.name,
          title = action.title or action.command or 'Untitled action',
          kind = action.kind,
          preferred = action.isPreferred == true,
          disabled = action.disabled and action.disabled.reason or nil,
          expiresAt = expires_at,
        }
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
  local action, client_or_error = resolve_action(transaction, context)
  if not action then
    transactions[id] = nil
    return { error = client_or_error }
  end
  local workspace_transaction, error = WorkspaceEdit.prepare({
    { edit = action.edit, encoding = client_or_error.offset_encoding or 'utf-16' },
  })
  if not workspace_transaction then
    transactions[id] = nil
    return { error = error }
  end
  if workspace_transaction.edits_count == 0 then
    transactions[id] = nil
    return { error = { code = 'code_action_no_edit', message = 'Code action returned no text edits' } }
  end
  transaction.workspace = workspace_transaction
  transaction.action = action
  return {
    operation = 'code_action_preview',
    actionId = id,
    title = action.title,
    kind = action.kind,
    filesChanged = workspace_transaction.files_changed,
    editsCount = workspace_transaction.edits_count,
    expiresAt = transaction.expires_at,
    changes = workspace_transaction.changes,
  }
end

local function file_quickfix_preview(context, operation)
  purge_expired()
  local edits = {}
  local titles = {}
  local clients = {}
  local seen = {}

  local function collect(client, params)
    local response = client:request_sync(operation.method, params, context.timeout_ms, context.bufnr)
    for _, action in ipairs(response and response.result or {}) do
      local temporary = { action = action, client_id = client.id }
      local resolved = resolve_action(temporary, context)
      if resolved and resolved.edit then
        local fingerprint = vim.fn.sha256(vim.json.encode({
          client = client.id,
          edit = resolved.edit,
        }))
        if not seen[fingerprint] then
          seen[fingerprint] = true
          edits[#edits + 1] = {
            edit = resolved.edit,
            encoding = client.offset_encoding or 'utf-16',
          }
          titles[#titles + 1] = resolved.title or 'Untitled action'
          clients[client.name] = true
        end
      end
    end
  end

  for _, client in ipairs(context.clients) do
    if client:supports_method(operation.method, context.bufnr) then
      collect(client, request_params(context, true))
      for _, diagnostic in ipairs(client_diagnostics(context, client)) do
        collect(client, diagnostic_params(context, diagnostic))
      end
    end
  end
  if #edits == 0 then
    return { error = { code = 'no_quickfixes', message = 'No editable quickfix actions found' } }
  end
  local workspace_transaction, error = WorkspaceEdit.prepare(edits)
  if not workspace_transaction then return { error = error } end
  local id = action_id('file-quickfix')
  local expires_at = os.time() + ttl_seconds
  transactions[id] = {
    workspace = workspace_transaction,
    expires_at = expires_at,
  }
  return {
    operation = operation.name,
    actionId = id,
    titles = titles,
    actionsCount = #titles,
    clients = (function()
      local names = vim.tbl_keys(clients)
      table.sort(names)
      return names
    end)(),
    filesChanged = workspace_transaction.files_changed,
    editsCount = workspace_transaction.edits_count,
    expiresAt = expires_at,
    changes = workspace_transaction.changes,
  }
end

local function apply(context)
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
    operation = 'code_action_apply',
    actionId = id,
    applied = true,
    saved = true,
    filesChanged = transaction.workspace.files_changed,
    editsCount = transaction.workspace.edits_count,
  }
end

---执行 Code Action 操作并维护 preview -> apply 的事务约束
---@param context VVMcpLspContext 请求上下文
---@param operation VVMcpLspOperation 操作定义
---@return table result
function M.request(context, operation)
  if operation.name == 'code_actions' then return list_actions(context, operation) end
  if operation.name == 'code_action_preview' then return preview(context) end
  if operation.name == 'file_quickfix_preview' then return file_quickfix_preview(context, operation) end
  return apply(context)
end

return M
