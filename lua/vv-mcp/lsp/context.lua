local Normalize = require('vv-mcp.lsp.normalize')

local M = {}

---@class VVMcpLspContext
---@field params table
---@field path string
---@field bufnr integer?
---@field timeout_ms integer
---@field clients vim.lsp.Client[]

---@param bufnr integer
---@param timeout_ms integer
---@param method string
---@return vim.lsp.Client[]
local function wait_for_clients(bufnr, timeout_ms, method)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  local function has_supporting_client()
    return vim.iter(clients):any(function(client)
      return client:supports_method(method, bufnr)
    end)
  end
  if has_supporting_client() then return clients end

  vim.wait(timeout_ms, function()
    clients = vim.lsp.get_clients({ bufnr = bufnr })
    return has_supporting_client()
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
  if operation.requires_query and type(params.query) ~= 'string' then
    return nil, {
      code = 'invalid_query',
      message = 'query is required for ' .. operation.name,
    }
  end
  if operation.requires_new_name and (type(params.newName) ~= 'string' or params.newName == '') then
    return nil, { code = 'invalid_new_name', message = 'newName is required for ' .. operation.name }
  end
  if operation.requires_rename_id and (type(params.renameId) ~= 'string' or params.renameId == '') then
    return nil, { code = 'invalid_rename_id', message = 'renameId is required for ' .. operation.name }
  end
  if operation.requires_action_id and (type(params.actionId) ~= 'string' or params.actionId == '') then
    return nil, { code = 'invalid_action_id', message = 'actionId is required for ' .. operation.name }
  end

  local path = Normalize.input_path(params.uri)
  local timeout_ms = type(params.timeoutMs) == 'number' and params.timeoutMs or 3000
  local bufnr
  local clients
  if operation.scope == 'workspace' then
    clients = vim.lsp.get_clients()
  else
    bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    clients = (operation.handler == 'diagnostics' or operation.name == 'rename_apply')
        and vim.lsp.get_clients({ bufnr = bufnr })
        or wait_for_clients(bufnr, timeout_ms, operation.method)
  end
  if #clients == 0 and operation.handler ~= 'diagnostics' and operation.name ~= 'rename_apply' then
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
