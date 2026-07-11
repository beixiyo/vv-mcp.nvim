---查询当前文档内同一语义符号的读、写与文本高亮范围
local Normalize = require('vv-mcp.lsp.normalize')

local M = {}

---向支持 documentHighlight 的客户端请求语义出现位置
---@param context VVMcpLspContext 请求上下文
---@param operation VVMcpLspOperation 操作定义
---@return table result
function M.request(context, operation)
  local results = {}
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(context.bufnr) },
    position = {
      line = context.params.line - 1,
      character = context.params.character - 1,
    },
  }
  for _, client in ipairs(context.clients) do
    if client:supports_method(operation.method, context.bufnr) then
      local response, error = client:request_sync(
        operation.method,
        params,
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
  return {
    operation = operation.name,
    path = Normalize.wire_path(context.path),
    results = results,
  }
end

return M
