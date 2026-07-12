local root = vim.fn.getcwd()
dofile(root .. '/tests/minimal_init.lua')

local Context = require('vv-mcp.lsp.context')
local Fs = require('vv-utils.fs')
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

local tmp = vim.fn.tempname()
local path = vim.fs.joinpath(tmp, 'external.ts')
Fs.mkdir_p(tmp)
Fs.write_all(path, 'before\n')
local bufnr = vim.fn.bufadd(path)
vim.fn.bufload(bufnr)
vim.uv.sleep(10)
Fs.write_all(path, 'after external write\n')

local _, no_lsp_error = Context.create({ uri = path }, {
  name = 'fix_document',
  method = 'textDocument/codeAction',
  scope = 'document',
  handler = 'code_actions',
  sync_from_disk = true,
})
assert(no_lsp_error.code == 'no_lsp')
assert(vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == 'after external write',
  'automatic fixes must observe the latest disk content')

vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'unsaved' })
local _, modified_error = Context.create({ uri = path }, {
  name = 'fix_document',
  method = 'textDocument/codeAction',
  scope = 'document',
  handler = 'code_actions',
  sync_from_disk = true,
})
assert(modified_error.code == 'buffer_modified', 'automatic fixes must preserve unsaved changes')
Fs.delete(tmp)

print('vv-mcp LSP context test: ok')
