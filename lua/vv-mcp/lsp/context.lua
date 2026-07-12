---负责校验 MCP 入参、加载目标 buffer，并发现能够响应请求的 LSP 客户端
local Normalize = require('vv-mcp.lsp.normalize')
local Fix = require('vv-utils.lsp.fix')

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

local function delete_temporary_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  if vim.bo[bufnr].modified or #vim.fn.win_findbuf(bufnr) > 0 then return end
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

---一次 LSP 操作共享的运行上下文
---@class VVMcpLspContext
---@field params table 原始 MCP 入参
---@field path string 已规范化的本地路径
---@field bufnr integer? 文档级操作对应的 buffer，工作区操作为空
---@field timeout_ms integer 单个 LSP 同步请求的超时时间
---@field clients vim.lsp.Client[] 当前作用域内可用的客户端
---@field pending_clients string[] 超时后仍未完成初始化、本次拿不到其修复项的客户端
---@field temporary boolean 是否由本次请求临时创建文档 buffer

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
  local attached_only = operation.handler == 'diagnostics' or operation.name == 'rename_apply'
  local bufnr
  local clients
  local pending = {}
  local temporary = false

  ---失败时不要留下本次请求临时创建的 buffer
  local function fail(error)
    if temporary then delete_temporary_buffer(bufnr) end
    return nil, error
  end

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
      if not Fix.supports_path(path) then
        return nil, {
          code = 'no_lsp',
          message = 'No enabled LSP configuration matches the document filetype',
          path = Normalize.wire_path(path),
        }
      end
      bufnr = vim.fn.bufadd(path)
      vim.fn.bufload(bufnr)
      temporary = true
    end
    if operation.sync_from_disk then
      local synced, sync_error = sync_from_disk(bufnr, path)
      if not synced then return fail(sync_error) end
    end
    if attached_only then
      clients = vim.lsp.get_clients({ bufnr = bufnr })
    else
      clients, pending = Fix.wait_for_clients(bufnr, {
        timeout_ms = timeout_ms,
        method = operation.method,
        wait_all = operation.wait_all_clients == true,
        allow_late_attach = temporary,
      })
    end
  end
  if #clients == 0 and not attached_only then
    return fail({
      code = 'no_lsp',
      message = 'No LSP client attached to buffer',
      path = Normalize.wire_path(path),
    })
  end

  return {
    params = params,
    path = path,
    bufnr = bufnr,
    timeout_ms = timeout_ms,
    clients = clients,
    pending_clients = pending,
    temporary = temporary,
  }
end

---清理由一次 CLI 请求临时创建且已经安全落盘的主文档 buffer
---@param context VVMcpLspContext
function M.cleanup(context)
  if context.temporary then delete_temporary_buffer(context.bufnr) end
end

return M
