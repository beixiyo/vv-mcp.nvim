---LSP 请求总入口：校验操作、构建请求上下文，并分发到对应的功能模块
local Context = require('vv-mcp.lsp.context')
local CallHierarchy = require('vv-mcp.lsp.call_hierarchy')
local CodeActions = require('vv-mcp.lsp.code_actions')
local Diagnostics = require('vv-mcp.lsp.diagnostics')
local DocumentFeatures = require('vv-mcp.lsp.document_features')
local Intelligence = require('vv-mcp.lsp.intelligence')
local Highlights = require('vv-mcp.lsp.highlights')
local Navigation = require('vv-mcp.lsp.navigation')
local Operations = require('vv-mcp.lsp.operations')
local Rename = require('vv-mcp.lsp.rename')
local Symbols = require('vv-mcp.lsp.symbols')

local M = {}

---执行一次由 MCP 转发而来的 LSP 操作
---@param params table MCP 入参，字段要求由具体操作定义
---@return table result 紧凑化之前的统一结果或错误对象
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

  local context, context_error = Context.create(params, operation)
  if not context then return { error = context_error } end

  local handlers = {
    navigation = Navigation,
    call_hierarchy = CallHierarchy,
    intelligence = Intelligence,
    document_features = DocumentFeatures,
    highlights = Highlights,
    symbols = Symbols,
    diagnostics = Diagnostics,
    rename = Rename,
    code_actions = CodeActions,
  }
  local ok, result = pcall(handlers[operation.handler].request, context, operation)
  if params.cleanupTemporary then Context.cleanup(context) end
  if not ok then error(result, 0) end
  return result
end

return M
