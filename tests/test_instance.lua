local root = vim.fn.getcwd()
dofile(root .. '/tests/minimal_init.lua')

local detected_root = '/tmp/vv-mcp-project-a'
package.loaded['vv-utils.path'] = {
  find_root = function() return detected_root end,
}

local Instance = require('vv-mcp.instance')
local first = Instance.current()
detected_root = '/tmp/vv-mcp-project-b'
local second = Instance.current()

assert(first.instanceId == second.instanceId,
  '当检测到项目根变化时 instanceId 应保持稳定')
assert(first.projectId == second.projectId,
  'projectId 应与稳定的 instanceId 保持一致')
assert(first.roots[1] ~= second.roots[1],
  '路由 roots 应独立于实例身份进行刷新')

print('vv-mcp 稳定实例身份测试通过')
