local Normalize = require('vv-mcp.lsp.normalize')

local M = {}

---@class VVMcpLspContext
---@field params table
---@field path string
---@field bufnr integer
---@field timeout_ms integer
---@field clients vim.lsp.Client[]

---@param bufnr integer
---@param timeout_ms integer
---@return vim.lsp.Client[]
local function wait_for_clients(bufnr, timeout_ms)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients > 0 then return clients end

  vim.wait(timeout_ms, function()
    clients = vim.lsp.get_clients({ bufnr = bufnr })
    return #clients > 0
  end, 20)

  return clients
end

---@param params table
---@param operation VVMcpLspOperation
---@return VVMcpLspContext?, table?
function M.create(params, operation)
  if operation.requires_position
      and (type(params.line) ~= 'number' or params.line < 1
        or type(params.character) ~= 'number' or params.character < 1) then
    return nil, {
      code = 'invalid_position',
      message = 'line and character must be 1-based positive integers',
    }
  end

  local path = Normalize.input_path(params.uri)
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  local timeout_ms = type(params.timeoutMs) == 'number' and params.timeoutMs or 3000
  local clients = wait_for_clients(bufnr, timeout_ms)
  if #clients == 0 then
    return nil, {
      code = 'no_lsp',
      message = 'No LSP client attached to buffer',
      path = Normalize.wire_path(path),
    }
  end

  return {
    params = params,
    path = path,
    bufnr = bufnr,
    timeout_ms = timeout_ms,
    clients = clients,
  }
end

return M
