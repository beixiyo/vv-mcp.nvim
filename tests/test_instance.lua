-- 真实场景在独立子进程中执行；收集阶段仅注册具名用例。
local H = dofile(vim.env.VV_TEST_REPO .. '/tests/helpers.lua')
local T, child = H.new_set({ setup = 'minimal_init.lua' })

T["项目根变化不改变实例身份但刷新路由根"] = function()
  child.lua_func(function()
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
  end)
end

return T
