local Context = require('vv-mcp.lsp.context')
local CodeActions = require('vv-mcp.lsp.code_actions')
local Diagnostics = require('vv-mcp.lsp.diagnostics')
local Intelligence = require('vv-mcp.lsp.intelligence')
local Highlights = require('vv-mcp.lsp.highlights')
local Navigation = require('vv-mcp.lsp.navigation')
local Operations = require('vv-mcp.lsp.operations')
local Rename = require('vv-mcp.lsp.rename')
local Symbols = require('vv-mcp.lsp.symbols')

local M = {}

---@param params table
---@return table
function M.request(params)
  local operation = Operations.get(params.operation)
  if not operation then
    return {
      error = {
        code = 'unsupported_operation',
        message = 'Unsupported LSP operation: ' .. tostring(params.operation),
      },
    }
  end

  local context, error = Context.create(params, operation)
  if not context then return { error = error } end

  local handlers = {
    navigation = Navigation,
    intelligence = Intelligence,
    highlights = Highlights,
    symbols = Symbols,
    diagnostics = Diagnostics,
    rename = Rename,
    code_actions = CodeActions,
  }
  return handlers[operation.handler].request(context, operation)
end

return M
