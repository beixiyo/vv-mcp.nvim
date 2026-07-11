---处理定义、声明、实现、引用等基于位置的导航请求
local Normalize = require('vv-mcp.lsp.normalize')
local PathOrigin = require('vv-mcp.lsp.path_origin')

local M = {}

local function filter_locations(value, client, include_external, path_pattern)
  if type(value) ~= 'table' then return value end
  local filtered = {}
  for _, location in ipairs(value) do
    local path = location.uri or location.targetUri
    local normalized = type(path) == 'string' and Normalize.wire_path(path) or ''
    local external_matches = include_external or PathOrigin.classify(client, normalized) == 'workspace'
    local path_matches = not path_pattern or normalized:lower():find(path_pattern, 1, true)
    if external_matches and path_matches then filtered[#filtered + 1] = location end
  end
  return filtered
end

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
        request_params.context = {
          includeDeclaration = context.params.includeDeclaration ~= false,
        }
      end

      local response, error = client:request_sync(
        operation.method,
        request_params,
        context.timeout_ms,
        context.bufnr
      )
      local result = response and Normalize.result(response.result) or nil
      if operation.name == 'references' then
        result = filter_locations(
          result,
          client,
          context.params.includeExternal ~= false,
          type(context.params.pathPattern) == 'string' and context.params.pathPattern:lower() or nil
        )
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
    line = context.params.line,
    character = context.params.character,
    results = results,
  }
end

return M
