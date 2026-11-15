---同步 LSP 请求的统一入口：把「没拿到响应」与「服务端返回错误」合并成一个错误出口
---
---client:request_sync 的第二个返回值只覆盖超时和发送失败；
---服务端的 ResponseError 放在 response.err 里，不在这里收口就会被当成空结果
local M = {}

---@param response_error lsp.ResponseError|table
---@return string
local function describe(response_error)
  local message = response_error.message or vim.inspect(response_error)
  if response_error.code == nil then return message end
  return ('%s (code %s)'):format(message, response_error.code)
end

---@param client vim.lsp.Client
---@param method string
---@param params table?
---@param context { timeout_ms: integer, bufnr: integer? }
---@return any result 原始 LSP 结果；出错或无结果时为 nil
---@return string? error
function M.sync(client, method, params, context)
  local response, request_error = client:request_sync(method, params, context.timeout_ms, context.bufnr)
  if request_error then return nil, tostring(request_error) end
  if not response then return nil, nil end
  if response.err then return nil, describe(response.err) end
  return response.result, nil
end

return M
