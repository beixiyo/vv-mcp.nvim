local root = vim.fn.getcwd()
dofile(root .. '/tests/minimal_init.lua')

local Context = require('vv-mcp.lsp.context')
local _, error = Context.create({ query = '' }, {
  name = 'workspace_symbols',
  requires_query = true,
})

assert(error.code == 'invalid_query', 'workspace_symbols must reject an empty query')

local missing = vim.fs.joinpath(vim.fn.tempname(), 'missing.ts')
local buffer_count = #vim.api.nvim_list_bufs()
local _, missing_error = Context.create({ uri = missing }, {
  name = 'hover',
  method = 'textDocument/hover',
  scope = 'document',
})

assert(missing_error.code == 'document_not_found', 'missing documents must be rejected')
assert(#vim.api.nvim_list_bufs() == buffer_count, 'missing documents must not create ghost buffers')

print('vv-mcp LSP context test: ok')
