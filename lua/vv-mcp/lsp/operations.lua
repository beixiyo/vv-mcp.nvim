local M = {}

---@class VVMcpLspOperation
---@field name string
---@field method string
---@field requires_position boolean
---@field scope 'document'|'workspace'
---@field handler 'navigation'|'intelligence'|'symbols'
---@field requires_query? boolean

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
}

---@param name string
---@return VVMcpLspOperation?
function M.get(name)
  return operations[name]
end

return M
