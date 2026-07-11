---处理文档符号大纲与工作区符号搜索
local Normalize = require('vv-mcp.lsp.normalize')

local M = {}

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
      results[#results + 1] = {
        client = client.name,
        result = response and Normalize.result(response.result) or nil,
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
