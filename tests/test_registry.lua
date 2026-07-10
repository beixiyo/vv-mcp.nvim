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

Registry.remove({ registry_dir = tmp }, instance.pid)
require('vv-utils.fs').delete(tmp)

print('vv-mcp registry test: ok')

