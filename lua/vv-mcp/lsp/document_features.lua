---处理无需符号位置的文档级能力：可跳转链接与内联提示
local Normalize = require('vv-mcp.lsp.normalize')

local M = {}

local function inlay_range(context, client)
  local line_count = vim.api.nvim_buf_line_count(context.bufnr)
  local start_line = math.min(context.params.startLine or 1, line_count)
  local end_line = math.min(context.params.endLine or line_count, line_count)
  local line = vim.api.nvim_buf_get_lines(context.bufnr, end_line - 1, end_line, false)[1] or ''
  local character = vim.lsp.util.character_offset(
    context.bufnr,
    end_line - 1,
    #line,
    client.offset_encoding or 'utf-16'
  )

  return {
    textDocument = { uri = vim.uri_from_bufnr(context.bufnr) },
    range = {
      start = { line = start_line - 1, character = 0 },
      ['end'] = { line = end_line - 1, character = character },
    },
  }
end

local function request_params(context, operation, client)
  if operation.name == 'inlay_hints' then return inlay_range(context, client) end
  return { textDocument = { uri = vim.uri_from_bufnr(context.bufnr) } }
end

---向所有支持目标能力的客户端请求文档特性
---@param context VVMcpLspContext 请求上下文
---@param operation VVMcpLspOperation 操作定义
---@return table result
function M.request(context, operation)
  local results = {}
  for _, client in ipairs(context.clients) do
    if client:supports_method(operation.method, context.bufnr) then
      local response, error = client:request_sync(
        operation.method,
        request_params(context, operation, client),
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
    results = results,
  }
end

return M
