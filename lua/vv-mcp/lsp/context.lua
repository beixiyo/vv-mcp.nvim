---负责校验 MCP 入参、加载目标 buffer，并发现能够响应请求的 LSP 客户端
local Normalize = require('vv-mcp.lsp.normalize')

local M = {}

local function loaded_buffer(path)
  local target = vim.fn.resolve(vim.fs.normalize(path))
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if vim.api.nvim_buf_is_loaded(bufnr)
        and name ~= ''
        and vim.fn.resolve(vim.fs.normalize(name)) == target then
      return bufnr
    end
  end
end

---一次 LSP 操作共享的运行上下文
---@class VVMcpLspContext
---@field params table 原始 MCP 入参
---@field path string 已规范化的本地路径
---@field bufnr integer? 文档级操作对应的 buffer，工作区操作为空
---@field timeout_ms integer 单个 LSP 同步请求的超时时间
---@field clients vim.lsp.Client[] 当前作用域内可用的客户端

---等待目标 buffer attach 至少一个支持指定方法的客户端
---@param bufnr integer buffer ID
---@param timeout_ms integer 最长等待时间
---@param method string LSP method
---@return vim.lsp.Client[] clients 返回当前 attach 的全部客户端，由处理器继续筛选能力
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

local function sync_from_disk(bufnr, path)
  if vim.bo[bufnr].modified then
    return false, {
      code = 'buffer_modified',
      message = 'Refusing to replace unsaved buffer changes before automatic LSP fixes',
      path = Normalize.wire_path(path),
    }
  end
  local ok, error = pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd('silent checktime')
  end)
  if not ok then
    return false, {
      code = 'buffer_sync_failed',
      message = tostring(error),
      path = Normalize.wire_path(path),
    }
  end
  return true
end

---校验操作参数并创建统一请求上下文
---@param params table MCP 入参
---@param operation VVMcpLspOperation 操作定义
---@return VVMcpLspContext? context
---@return table? error
function M.create(params, operation)
  if operation.requires_position
      and (type(params.line) ~= 'number' or params.line < 1
        or type(params.character) ~= 'number' or params.character < 1) then
    return nil, {
      code = 'invalid_position',
      message = 'line and character must be 1-based positive integers',
    }
  end
  if operation.requires_query and (type(params.query) ~= 'string' or params.query == '') then
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
  if operation.requires_call_id and (type(params.callId) ~= 'string' or params.callId == '') then
    return nil, { code = 'invalid_call_id', message = 'callId is required for ' .. operation.name }
  end
  if operation.name == 'inlay_hints' then
    if params.startLine ~= nil and (type(params.startLine) ~= 'number' or params.startLine < 1) then
      return nil, { code = 'invalid_range', message = 'startLine must be a 1-based positive integer' }
    end
    if params.endLine ~= nil and (type(params.endLine) ~= 'number' or params.endLine < 1) then
      return nil, { code = 'invalid_range', message = 'endLine must be a 1-based positive integer' }
    end
    if params.startLine and params.endLine and params.startLine > params.endLine then
      return nil, { code = 'invalid_range', message = 'startLine must not exceed endLine' }
    end
  end

  local path = Normalize.input_path(params.uri)
  local timeout_ms = type(params.timeoutMs) == 'number' and params.timeoutMs or 3000
  local bufnr
  local clients
  if operation.scope == 'workspace' then
    clients = vim.lsp.get_clients()
  else
    bufnr = loaded_buffer(path)
    if not bufnr then
      if not vim.uv.fs_lstat(path) then
        return nil, {
          code = 'document_not_found',
          message = 'Document does not exist and is not loaded in this Neovim instance',
          path = Normalize.wire_path(path),
        }
      end
      bufnr = vim.fn.bufadd(path)
      vim.fn.bufload(bufnr)
    end
    if operation.sync_from_disk then
      local synced, sync_error = sync_from_disk(bufnr, path)
      if not synced then return nil, sync_error end
    end
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
