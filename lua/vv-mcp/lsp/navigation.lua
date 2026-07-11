---处理定义、声明、实现、引用等基于位置的导航请求
local Normalize = require('vv-mcp.lsp.normalize')

local M = {}

---向所有支持目标 method 的客户端请求导航结果
---@param context VVMcpLspContext 请求上下文
---@param operation VVMcpLspOperation 操作定义
---@return table result 按实际响应客户端保留来源
function M.request(context, operation)
  local results = {}
  for _, client in ipairs(context.clients) do
    if client:supports_method(operation.method, context.bufnr) then
      local request_params = {
        textDocument = { uri = vim.uri_from_bufnr(context.bufnr) },
        position = {
          line = context.params.line - 1,
          character = context.params.character - 1,
        },
      }
      if operation.name == 'references' then
        request_params.context = { includeDeclaration = true }
      end

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
    line = context.params.line,
    character = context.params.character,
    results = results,
  }
end

return M
