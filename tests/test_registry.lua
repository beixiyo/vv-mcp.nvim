local root = vim.fn.getcwd()
dofile(root .. '/tests/minimal_init.lua')

local tmp = vim.fn.tempname()
require('vv-mcp').setup({ registry_dir = tmp })

local Registry = require('vv-mcp.registry')
local Instance = require('vv-mcp.instance')
local instance = Instance.current()
local path = Registry.path({ registry_dir = tmp }, instance.pid)

assert(vim.uv.fs_stat(path), 'registry file should exist')

local data = vim.json.decode(require('vv-utils.fs').read_all(path))
assert(data.pid == vim.fn.getpid(), 'registry pid should match Neovim')
assert(data.instanceId:match(':' .. data.pid .. '$'), 'instance id should include pid')
assert(data.socket ~= '', 'Neovim RPC socket should be published')
assert(data.cwd == vim.fs.normalize(vim.fn.getcwd()), 'cwd should use normalized wire path')
local root_is_absolute = data.roots[1]:sub(1, 1) == '/'
  or data.roots[1]:match('^%a:[/\\]') ~= nil
assert(root_is_absolute, 'registry roots should use absolute paths')
assert(not data.projectId:match('^%.%-'), 'project id should use the absolute root basename')

local invalid = require('vv-mcp.lsp').request({
  operation = 'definition',
  uri = '/tmp/example.lua',
  line = 0,
  character = 1,
})
assert(invalid.error.code == 'invalid_position', 'LSP positions should be 1-based')

local Operations = require('vv-mcp.lsp.operations')
assert(Operations.get('workspace_symbols').requires_query, 'workspace symbols should require query')
assert(not Operations.get('document_symbols').requires_position, 'document symbols should not require position')
assert(Operations.get('type_definition').handler == 'navigation', 'type definition should use navigation')

Registry.remove({ registry_dir = tmp }, instance.pid)
require('vv-utils.fs').delete(tmp)

print('vv-mcp registry test: ok')
