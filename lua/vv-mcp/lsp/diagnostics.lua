local Normalize = require('vv-mcp.lsp.normalize')

local M = {}

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

---@param context VVMcpLspContext
---@param operation VVMcpLspOperation
---@return table
function M.request(context, operation)
  local diagnostics = vim.diagnostic.get(
    operation.scope == 'document' and context.bufnr or nil
  )
  local items = {}
  local root = Normalize.wire_path(vim.fn.resolve(context.path))
  for _, diagnostic in ipairs(diagnostics) do
    local item = compact(diagnostic)
    if item.path ~= '' and (operation.scope == 'document' or is_under(root, item.path)) then
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
