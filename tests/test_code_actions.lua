local root = vim.fn.getcwd()
dofile(root .. '/tests/minimal_init.lua')

local Fs = require('vv-utils.fs')
local CodeActions = require('vv-mcp.lsp.code_actions')
local tmp = vim.fn.tempname()
local path = vim.fs.joinpath(tmp, 'fixture.tsx')
local original = 'rounded-[8px] p-[16px]'

Fs.mkdir_p(tmp)
Fs.write_all(path, original .. '\n')
local bufnr = vim.fn.bufadd(path)
vim.fn.bufload(bufnr)

local client = {
  id = 901,
  name = 'fixture-lsp',
  offset_encoding = 'utf-16',
  supports_method = function() return true end,
  request_sync = function()
    return {
      result = {
        {
          title = 'Fix rounded',
          kind = 'quickfix',
          edit = { changes = { [vim.uri_from_fname(path)] = {{
            range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 13 } },
            newText = 'rounded-lg',
          }} } },
        },
        {
          title = 'Fix padding',
          kind = 'quickfix',
          edit = { changes = { [vim.uri_from_fname(path)] = {{
            range = { start = { line = 0, character = 14 }, ['end'] = { line = 0, character = 22 } },
            newText = 'p-4',
          }} } },
        },
      },
    }
  end,
}

local original_get_client = vim.lsp.get_client_by_id
vim.lsp.get_client_by_id = function(id)
  return id == client.id and client or nil
end

local function context(params)
  return {
    params = params,
    path = path,
    bufnr = bufnr,
    timeout_ms = 1000,
    clients = { client },
  }
end

local listed = CodeActions.request(context({ line = 1, character = 1 }), {
  name = 'code_actions',
  method = 'textDocument/codeAction',
})
assert(#listed.items == 2, 'fixture should expose two editable actions')

local first_id = listed.items[1].actionId
local second_id = listed.items[2].actionId
local first_preview = CodeActions.request(context({ actionId = first_id }), {
  name = 'code_action_preview',
})
assert(not first_preview.error, vim.inspect(first_preview.error))
local first_apply = CodeActions.request(context({ actionId = first_id }), {
  name = 'code_action_apply',
})
assert(first_apply.applied == true, vim.inspect(first_apply))
assert(Fs.read_all(path) == 'rounded-lg p-[16px]\n', 'first action should save the expected edit')

local stale_preview = CodeActions.request(context({ actionId = second_id }), {
  name = 'code_action_preview',
})
assert(stale_preview.error.code == 'workspace_edit_stale', 'old sibling actions must become stale')
assert(Fs.read_all(path) == 'rounded-lg p-[16px]\n', 'stale action must not corrupt the file')

vim.lsp.get_client_by_id = original_get_client
Fs.delete(tmp)

print('vv-mcp code action stale test: ok')
