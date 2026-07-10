local Normalize = require('vv-mcp.lsp.normalize')

local M = {}

---@param context VVMcpLspContext
---@param operation VVMcpLspOperation
---@return table
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
