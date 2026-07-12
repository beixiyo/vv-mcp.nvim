local root = vim.fn.getcwd()
dofile(root .. '/tests/minimal_init.lua')

local detected_root = '/tmp/vv-mcp-project-a'
package.loaded['vv-utils.path'] = {
  get_root = function() return detected_root end,
}

local Instance = require('vv-mcp.instance')
local first = Instance.current()
detected_root = '/tmp/vv-mcp-project-b'
local second = Instance.current()

assert(first.instanceId == second.instanceId,
  'instanceId must remain stable when the detected project root changes')
assert(first.projectId == second.projectId,
  'projectId must remain aligned with the stable instanceId')
assert(first.roots[1] ~= second.roots[1],
  'routing roots should still refresh independently from instance identity')

print('vv-mcp stable instance identity test: ok')
