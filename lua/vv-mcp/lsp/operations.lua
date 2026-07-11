---集中声明所有对外开放的 LSP 操作及其校验、路由元数据
local M = {}

---LSP 操作定义
---@class VVMcpLspOperation
---@field name string 对外暴露的 operation 名称
---@field method string 对应的 LSP method 或 Neovim 内部诊断方法
---@field requires_position boolean 是否要求 1-based 的 line 与 character
---@field scope 'document'|'workspace' 请求作用域
---@field handler 'navigation'|'intelligence'|'document_features'|'symbols'|'diagnostics'|'highlights'|'rename'|'code_actions' 处理模块
---@field requires_query? boolean 是否要求符号搜索词
---@field requires_new_name? boolean 是否要求新符号名
---@field requires_rename_id? boolean 是否要求重命名事务 ID
---@field requires_action_id? boolean 是否要求 Code Action 事务 ID

---@type table<string, VVMcpLspOperation>
local operations = {
  definition = {
    name = 'definition',
    method = 'textDocument/definition',
    requires_position = true,
    scope = 'document',
    handler = 'navigation',
  },
  declaration = {
    name = 'declaration',
    method = 'textDocument/declaration',
    requires_position = true,
    scope = 'document',
    handler = 'navigation',
  },
  type_definition = {
    name = 'type_definition',
    method = 'textDocument/typeDefinition',
    requires_position = true,
    scope = 'document',
    handler = 'navigation',
  },
  implementation = {
    name = 'implementation',
    method = 'textDocument/implementation',
    requires_position = true,
    scope = 'document',
    handler = 'navigation',
  },
  references = {
    name = 'references',
    method = 'textDocument/references',
    requires_position = true,
    scope = 'document',
    handler = 'navigation',
  },
  document_highlight = {
    name = 'document_highlight',
    method = 'textDocument/documentHighlight',
    requires_position = true,
    scope = 'document',
    handler = 'highlights',
  },
  hover = {
    name = 'hover',
    method = 'textDocument/hover',
    requires_position = true,
    scope = 'document',
    handler = 'intelligence',
  },
  signature_help = {
    name = 'signature_help',
    method = 'textDocument/signatureHelp',
    requires_position = true,
    scope = 'document',
    handler = 'intelligence',
  },
  document_links = {
    name = 'document_links',
    method = 'textDocument/documentLink',
    requires_position = false,
    scope = 'document',
    handler = 'document_features',
  },
  inlay_hints = {
    name = 'inlay_hints',
    method = 'textDocument/inlayHint',
    requires_position = false,
    scope = 'document',
    handler = 'document_features',
  },
  document_symbols = {
    name = 'document_symbols',
    method = 'textDocument/documentSymbol',
    requires_position = false,
    scope = 'document',
    handler = 'symbols',
  },
  workspace_symbols = {
    name = 'workspace_symbols',
    method = 'workspace/symbol',
    requires_position = false,
    requires_query = true,
    scope = 'workspace',
    handler = 'symbols',
  },
  diagnostics = {
    name = 'diagnostics',
    method = 'vim.diagnostic.get',
    requires_position = false,
    scope = 'document',
    handler = 'diagnostics',
  },
  workspace_diagnostics = {
    name = 'workspace_diagnostics',
    method = 'vim.diagnostic.get',
    requires_position = false,
    scope = 'workspace',
    handler = 'diagnostics',
  },
  code_actions = {
    name = 'code_actions',
    method = 'textDocument/codeAction',
    requires_position = true,
    scope = 'document',
    handler = 'code_actions',
  },
  code_action_preview = {
    name = 'code_action_preview',
    method = 'textDocument/codeAction',
    requires_position = false,
    requires_action_id = true,
    scope = 'document',
    handler = 'code_actions',
  },
  file_quickfix_preview = {
    name = 'file_quickfix_preview',
    method = 'textDocument/codeAction',
    requires_position = false,
    scope = 'document',
    handler = 'code_actions',
  },
  code_action_apply = {
    name = 'code_action_apply',
    method = 'textDocument/codeAction',
    requires_position = false,
    requires_action_id = true,
    scope = 'document',
    handler = 'code_actions',
  },
  prepare_rename = {
    name = 'prepare_rename',
    method = 'textDocument/prepareRename',
    requires_position = true,
    scope = 'document',
    handler = 'rename',
  },
  rename_preview = {
    name = 'rename_preview',
    method = 'textDocument/rename',
    requires_position = true,
    requires_new_name = true,
    scope = 'document',
    handler = 'rename',
  },
  rename_apply = {
    name = 'rename_apply',
    method = 'workspace/applyEdit',
    requires_position = false,
    requires_rename_id = true,
    scope = 'document',
    handler = 'rename',
  },
}

---按对外 operation 名称查询操作定义
---@param name string 操作名称
---@return VVMcpLspOperation? operation 未注册时返回 nil
function M.get(name)
  return operations[name]
end

return M
