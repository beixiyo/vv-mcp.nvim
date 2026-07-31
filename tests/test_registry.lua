local root = vim.fn.getcwd()
dofile(root .. '/tests/minimal_init.lua')

local tmp = vim.fn.tempname()
require('vv-mcp').setup({
  registry_dir = tmp,
  server = { auto_install = false },
})

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

local second_tmp = vim.fn.tempname()
vim.api.nvim_exec_autocmds('FocusGained', {})
require('vv-mcp').setup({
  registry_dir = second_tmp,
  server = { auto_install = false },
})
vim.wait(20)
assert(not vim.uv.fs_stat(path), 'reconfiguring registry_dir should remove the old registry')

local second_path = Registry.path({ registry_dir = second_tmp }, instance.pid)
assert(vim.uv.fs_stat(second_path), 'reconfiguring registry_dir should register in the new directory')
Registry.remove({ registry_dir = second_tmp }, instance.pid)
vim.cmd('VVMcpRefresh')
assert(vim.uv.fs_stat(second_path), 'reconfigured refresh command should use the new registry directory')
assert(not vim.uv.fs_stat(path), 'reconfigured refresh command should not recreate the old registry')

require('vv-mcp').setup({
  enabled = false,
  registry_dir = second_tmp,
  server = { auto_install = false },
})
vim.cmd('VVMcpRefresh')
vim.wait(20)
assert(not vim.uv.fs_stat(second_path), 'disabled setup and refresh should keep the registry absent')

local Binary = require('vv-mcp.binary')
local original_ensure = Binary.ensure
local original_install = Binary.install
local command_install_dir
Binary.install = function(server, _, callback)
  command_install_dir = server.install_dir
  callback({ ok = true, version = 'fixture', path = '/tmp/vv-mcp-fixture' })
end
require('vv-mcp').setup({
  enabled = false,
  registry_dir = second_tmp,
  server = { auto_install = false, install_dir = '/tmp/vv-mcp-old-install' },
})
require('vv-mcp').setup({
  enabled = false,
  registry_dir = second_tmp,
  server = { auto_install = false, install_dir = '/tmp/vv-mcp-new-install' },
})
vim.cmd('VVMcpInstall')
Binary.install = original_install
assert(command_install_dir == '/tmp/vv-mcp-new-install',
  'reconfigured install command should use the new server config')

local ensure_calls = 0
Binary.ensure = function(_, callback)
  ensure_calls = ensure_calls + 1
  callback({ ok = true, changed = false })
end
require('vv-mcp').setup({
  registry_dir = second_tmp,
  server = { auto_install = true },
})
require('vv-mcp').setup({
  enabled = false,
  registry_dir = second_tmp,
  server = { auto_install = false },
})
vim.wait(20)
Binary.ensure = original_ensure
assert(ensure_calls == 0, 'a stale scheduled auto-install should not use the old config')

local original_get_clients = vim.lsp.get_clients
vim.lsp.get_clients = function()
  return {{
    name = 'fixture-lsp',
    workspace_folders = {{
      uri = vim.uri_from_fname(vim.fs.joinpath(vim.fn.tempname(), 'unrelated-project')),
    }},
  }}
end
local isolated = Instance.current()
local expected_root = require('vv-utils.path').find_root(isolated.cwd) or isolated.cwd
assert(vim.deep_equal(isolated.roots, { expected_root }),
  'LSP workspace folders must not expand the instance project scope')
vim.lsp.get_clients = original_get_clients

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
Registry.remove({ registry_dir = second_tmp }, instance.pid)
require('vv-utils.fs').delete(tmp)
require('vv-utils.fs').delete(second_tmp)

print('vv-mcp registry test: ok')
