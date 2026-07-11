---管理调用层级节点，并查询一层调用者或被调用者
local Normalize = require('vv-mcp.lsp.normalize')

local M = {}
local nodes = {}
local ttl_seconds = 300

local function node_id(seed)
  return vim.fn.sha256(table.concat({
    tostring(vim.fn.getpid()), tostring(vim.uv.hrtime()), seed,
  }, ':')):sub(1, 24)
end

local function purge_expired()
  local now = os.time()
  for id, node in pairs(nodes) do
    if now > node.expires_at then nodes[id] = nil end
  end
end

local function store_node(client, item)
  local id = node_id(item.name or client.name)
  local expires_at = os.time() + ttl_seconds
  nodes[id] = {
    client_id = client.id,
    item = item,
    expires_at = expires_at,
  }
  local output = vim.deepcopy(item)
  Normalize.result(output)
  output.callId = id
  output.expiresAt = expires_at
  return output
end

local function prepare(context, operation)
  purge_expired()
  local items = {}
  local errors = {}
  local supported = false
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(context.bufnr) },
    position = {
      line = context.params.line - 1,
      character = context.params.character - 1,
    },
  }
  for _, client in ipairs(context.clients) do
    if client:supports_method(operation.method, context.bufnr) then
      supported = true
      local response, error = client:request_sync(
        operation.method, params, context.timeout_ms, context.bufnr
      )
      if error then errors[client.name] = tostring(error) end
      for _, item in ipairs(response and response.result or {}) do
        local output = store_node(client, item)
        output.client = client.name
        items[#items + 1] = output
      end
    end
  end
  if not supported then
    return {
      error = {
        code = 'capability_unsupported',
        message = 'Attached LSP clients do not support ' .. operation.method,
        clients = vim.tbl_map(function(client) return client.name end, context.clients),
      },
    }
  end
  return { operation = operation.name, items = items, errors = errors }
end

local function calls(context, operation)
  purge_expired()
  local id = context.params.callId
  local node = nodes[id]
  if not node then
    return { error = { code = 'call_node_not_found', message = 'Call hierarchy node not found or expired' } }
  end
  local client = vim.lsp.get_client_by_id(node.client_id)
  if not client then
    nodes[id] = nil
    return { error = { code = 'call_client_gone', message = 'The LSP client is no longer active' } }
  end
  local response, error = client:request_sync(
    operation.method, { item = node.item }, context.timeout_ms, context.bufnr
  )
  if error then
    return { error = { code = 'call_hierarchy_failed', message = tostring(error), client = client.name } }
  end

  local items = {}
  for _, call in ipairs(response and response.result or {}) do
    local target = operation.name == 'incoming_calls' and call.from or call.to
    if target then
      items[#items + 1] = {
        node = store_node(client, target),
        fromRanges = Normalize.result(vim.deepcopy(call.fromRanges or {})),
      }
    end
  end
  return {
    operation = operation.name,
    client = client.name,
    sourceCallId = id,
    calls = items,
  }
end

---执行调用层级准备或单层图查询
---@param context VVMcpLspContext 请求上下文
---@param operation VVMcpLspOperation 操作定义
---@return table result
function M.request(context, operation)
  if operation.name == 'prepare_call_hierarchy' then return prepare(context, operation) end
  return calls(context, operation)
end

return M
