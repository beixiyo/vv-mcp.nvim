local M = {}

---@class VVMcpLspOperation
---@field name string
---@field method string
---@field requires_position boolean
---@field scope 'document'|'workspace'
---@field handler 'navigation'|'intelligence'|'symbols'|'diagnostics'|'rename'
---@field requires_query? boolean
---@field requires_new_name? boolean
---@field requires_rename_id? boolean

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

---@param name string
---@return VVMcpLspOperation?
function M.get(name)
  return operations[name]
end

return M
