---处理文档符号大纲与工作区符号搜索
local Normalize = require('vv-mcp.lsp.normalize')

local M = {}

local function filter_symbols(symbols, query, allowed_kinds)
  if type(symbols) ~= 'table' then return symbols end

  local filtered = {}
  for _, symbol in ipairs(symbols) do
    local children = filter_symbols(symbol.children, query, allowed_kinds)
    local name_matches = not query
      or (type(symbol.name) == 'string' and symbol.name:lower():find(query, 1, true))
    local kind_name = vim.lsp.protocol.SymbolKind[symbol.kind]
    local kind_matches = not allowed_kinds
      or (kind_name and allowed_kinds[kind_name:lower()])
    if name_matches and kind_matches then
      local output = vim.deepcopy(symbol)
      output.children = children
      filtered[#filtered + 1] = output
    elseif #children > 0 then
      vim.list_extend(filtered, children)
    end
  end
  return filtered
end

---请求符号并保留每个实际响应的 LSP 客户端来源
---@param context VVMcpLspContext 请求上下文
---@param operation VVMcpLspOperation 操作定义
---@return table result
function M.request(context, operation)
  local results = {}
  for _, client in ipairs(context.clients) do
    if client:supports_method(operation.method, context.bufnr) then
      local request_params = operation.scope == 'workspace'
          and { query = context.params.query }
          or { textDocument = { uri = vim.uri_from_bufnr(context.bufnr) } }
      local response, error = client:request_sync(
        operation.method,
        request_params,
        context.timeout_ms,
        context.bufnr
      )
      local result = response and Normalize.result(response.result) or nil
      if operation.name == 'document_symbols' then
        local query = type(context.params.query) == 'string'
            and context.params.query:lower()
            or nil
        local allowed_kinds = type(context.params.symbolKinds) == 'table'
            and vim.iter(context.params.symbolKinds):fold({}, function(output, kind)
              output[kind:gsub('_', '')] = true
              return output
            end)
            or nil
        result = filter_symbols(result, query, allowed_kinds)
      end
      results[#results + 1] = {
        client = client.name,
        result = result,
        error = error and tostring(error) or nil,
      }
    end
  end

  if #results == 0 then
    return {
      error = {
        code = 'capability_unsupported',
        message = 'Attached LSP clients do not support ' .. operation.method,
        clients = vim.tbl_map(function(client) return client.name end, context.clients),
      },
    }
  end

  return {
    operation = operation.name,
    path = Normalize.wire_path(context.path),
    query = context.params.query,
    results = results,
  }
end

return M
