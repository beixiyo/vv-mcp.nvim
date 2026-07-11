---读取 Neovim 已发布的实时诊断，并按文件或工作区范围过滤
local Normalize = require('vv-mcp.lsp.normalize')

local M = {}

local severity_names = {
  [vim.diagnostic.severity.ERROR] = 'error',
  [vim.diagnostic.severity.WARN] = 'warning',
  [vim.diagnostic.severity.INFO] = 'information',
  [vim.diagnostic.severity.HINT] = 'hint',
}

local function is_under(root, path)
  if path == root then return true end
  local prefix = root:sub(-1) == '/' and root or root .. '/'
  return path:sub(1, #prefix) == prefix
end

local function compact(diagnostic)
  local path = vim.api.nvim_buf_get_name(diagnostic.bufnr)
  return {
    path = Normalize.wire_path(vim.fs.normalize(path)),
    range = {
      start = { line = diagnostic.lnum + 1, character = diagnostic.col + 1 },
      ['end'] = {
        line = (diagnostic.end_lnum or diagnostic.lnum) + 1,
        character = (diagnostic.end_col or diagnostic.col) + 1,
      },
    },
    severity = diagnostic.severity,
    message = diagnostic.message,
    source = diagnostic.source,
    code = diagnostic.code,
  }
end

---返回当前 Neovim 实例已经持有的诊断，不额外触发 LSP 请求
---@param context VVMcpLspContext 请求上下文
---@param operation VVMcpLspOperation 操作定义
---@return table result
function M.request(context, operation)
  local diagnostics = vim.diagnostic.get(
    operation.scope == 'document' and context.bufnr or nil
  )
  local items = {}
  local allowed_severities = type(context.params.severities) == 'table'
      and vim.iter(context.params.severities):fold({}, function(result, severity)
        result[severity] = true
        return result
      end)
      or nil
  local allowed_sources = type(context.params.sources) == 'table'
      and vim.iter(context.params.sources):fold({}, function(result, source)
        result[source:lower()] = true
        return result
      end)
      or nil
  local root = Normalize.wire_path(vim.fn.resolve(context.path))
  for _, diagnostic in ipairs(diagnostics) do
    local item = compact(diagnostic)
    local severity_matches = not allowed_severities
      or allowed_severities[severity_names[diagnostic.severity]]
    local source_matches = not allowed_sources
      or (type(diagnostic.source) == 'string' and allowed_sources[diagnostic.source:lower()])
    if severity_matches and source_matches
        and item.path ~= '' and (operation.scope == 'document' or is_under(root, item.path)) then
      items[#items + 1] = item
    end
  end

  return {
    operation = operation.name,
    path = Normalize.wire_path(context.path),
    diagnostics = items,
  }
end

return M
