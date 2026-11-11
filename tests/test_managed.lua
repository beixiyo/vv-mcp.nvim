local H = dofile(vim.env.VV_TEST_REPO .. '/tests/helpers.lua')
local T, child = H.new_set({ setup = 'minimal_init.lua' })

local function fixture()
  child.lua_func(function()
    vim.env.VV_MCP_MANAGED = '1'
    vim.env.VV_MCP_MANAGED_IDLE_TIMEOUT_MS = '100'
    vim.env.VV_MCP_MANAGED_READY_TIMEOUT_MS = '150'
    vim.env.VV_MCP_MANAGED_WATCH_INTERVAL_MS = '5'
    vim.env.VV_MCP_MANAGED_HANDOFF_DELAY_MS = '50'
    Expired = 0
    local command = vim.cmd
    -- 只替换最终退出边界，真实 timer、租期、请求入口和注册表发现均走生产代码
    vim.cmd = setmetatable({}, {
      __index = command,
      __call = function(_, text)
        if text == 'silent! qa!' then Expired = Expired + 1 else return command(text) end
      end,
    })
    Config = require('vv-mcp.config').resolve({
      registry_dir = vim.env.VV_TEST_TMP .. '/registry',
      server = { auto_install = false },
    })
    require('vv-mcp.lifecycle').setup(Config)
  end)
end

T['短调用不会缩短长租期且后续请求可以续期'] = function()
  fixture()
  child.lua_func(function()
    local Managed = require('vv-mcp.managed')
    Managed.retain(300)
    Managed.run(function() return true end, 20)
    vim.wait(180, function() return Expired > 0 end, 5)
    assert(Expired == 0, '短租期不能缩短前一个调用者的保活')
    Managed.run(function() return true end, 250)
    vim.wait(170, function() return Expired > 0 end, 5)
    assert(Expired == 0, '后续调用必须把实例续期到原过期时间之后')
    assert(vim.wait(300, function() return Expired == 1 end, 5), '空闲后应自行回收')
    Managed.stop()
    Managed.stop()
  end)
end

T['执行中不回收并从完成时间续期，异常不会遗留活跃计数'] = function()
  fixture()
  child.lua_func(function()
    local Managed = require('vv-mcp.managed')
    Managed.retain(30)
    assert(Managed.run(function()
      vim.wait(120, function() return Expired > 0 end, 5)
      assert(Expired == 0, '执行中的请求不能被 idle timer 关闭')
      return 'done'
    end, 30) == 'done')
    local ok = pcall(Managed.run, function() error('fixture failure') end, 30)
    assert(not ok, '请求错误必须继续向调用方抛出')
    assert(Expired == 0, '完成时不能立即回收')
    assert(vim.wait(200, function() return Expired == 1 end, 5), '异常必须释放活跃计数')
  end)
end

T['只向同项目的真实交互式实例交接且执行中不退出'] = function()
  fixture()
  child.lua_func(function()
    local Fs = require('vv-utils.fs')
    local Registry = require('vv-mcp.registry')
    local Instance = require('vv-mcp.instance')
    local Managed = require('vv-mcp.managed')
    Managed.retain(5000)
    local other = Instance.current()
    other.pid = vim.uv.os_getppid()
    other.kind = 'interactive'
    local roots = other.roots
    other.roots = { vim.env.VV_TEST_TMP .. '/different-project' }
    Registry.write(Config, other)
    vim.wait(80, function() return Expired > 0 end, 5)
    assert(Expired == 0, '其他项目不应触发交接')
    other.roots = roots
    other.socket = vim.env.VV_TEST_TMP .. '/missing.sock'
    Registry.write(Config, other)
    vim.wait(200, function() return Expired > 0 end, 5)
    assert(Expired == 0, 'PID 存活但 socket 不可用不能触发交接')
    Fs.delete(Registry.path(Config, other.pid))

    -- macOS Unix socket 地址有长度上限，不能使用层级较深的测试 HOME 路径
    local peer_root = assert(vim.uv.fs_mkdtemp('/tmp/vv-mcp-peer-XXXXXX'))
    local socket = peer_root .. '/peer.sock'
    local marker = vim.env.VV_TEST_TMP .. '/interactive-started'
    local script = string.format(
      'lua vim.opt.rtp:prepend(%q); vim.opt.rtp:prepend(%q); require("vv-mcp").setup({registry_dir=%q, server={auto_install=false}}); vim.fn.writefile({tostring(vim.fn.getpid())}, %q)',
      vim.env.VV_UTILS, vim.env.VV_TEST_REPO, Registry.dir(Config), marker
    )
    local peer = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '--listen', socket, '-c', script }, {
      env = { VV_MCP_MANAGED = '0' },
    })
    local ok, err = pcall(function()
      Managed.run(function()
        assert(vim.wait(2000, function() return vim.uv.fs_stat(marker) ~= nil end, 5), '交互式实例应成功启动')
        vim.wait(250, function() return Expired > 0 end, 5)
        assert(Expired == 0, '交接也不能中断正在执行的请求')
      end, 50)
      assert(vim.wait(1500, function() return Expired == 1 end, 5), '验证真实接管实例后应回收')
    end)
    peer:kill(15)
    local result = peer:wait(1000)
    vim.fn.delete(peer_root, 'rf')
    assert(ok, tostring(err) .. '\n' .. (result.stderr or ''))
  end)
end

T['交互实例切走项目后不能凭旧身份或过期注册记录接管'] = function()
  fixture()
  child.lua_func(function()
    local Managed = require('vv-mcp.managed')
    local Registry = require('vv-mcp.registry')
    Managed.retain(5000)
    local project = vim.fn.getcwd()
    local other = vim.env.VV_TEST_TMP .. '/other-project'
    vim.fn.mkdir(other .. '/.git', 'p')
    local peer_root = assert(vim.uv.fs_mkdtemp('/tmp/vv-mcp-moved-XXXXXX'))
    local socket = peer_root .. '/peer.sock'
    local marker = vim.env.VV_TEST_TMP .. '/moved-started'
    local script = string.format(
      'lua vim.opt.rtp:prepend(%q); vim.opt.rtp:prepend(%q); require("vv-mcp").setup({registry_dir=%q, server={auto_install=false}}); local config=require("vv-mcp").get_config(); local old=require("vv-mcp.instance").current(); vim.cmd.cd(%q); require("vv-mcp.registry").write(config, old); vim.fn.writefile({tostring(vim.fn.getpid())}, %q)',
      vim.env.VV_UTILS, vim.env.VV_TEST_REPO, Registry.dir(Config), other, marker
    )
    local peer = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '--listen', socket, '-c', script }, {
      env = { VV_MCP_MANAGED = '0' },
    })
    local ok, err = pcall(function()
      assert(vim.wait(2000, function() return vim.uv.fs_stat(marker) ~= nil end, 5), '交互式实例应成功启动并切到其他项目')
      vim.wait(350, function() return Expired > 0 end, 5)
      assert(Expired == 0, '实时路由根已变化，旧身份和过期注册记录不能触发交接')
      local expression = string.format('luaeval(%q)', 'vim.cmd.cd(' .. string.format('%q', project) .. ')')
      local moved = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '--server', socket, '--remote-expr', expression }, { text = true }):wait(2000)
      assert(moved.code == 0, moved.stderr)
      assert(vim.wait(1500, function() return Expired == 1 end, 5), '实时路由根重新覆盖项目后应正常交接')
    end)
    peer:kill(15)
    local result = peer:wait(1000)
    vim.fn.delete(peer_root, 'rf')
    assert(ok, tostring(err) .. '\n' .. (result.stderr or ''))
  end)
end

T['共享预热返回可重试状态且不会因原请求完成而丢失租期'] = function()
  fixture()
  child.lua_func(function()
    local Managed = require('vv-mcp.managed')
    local params = { operation = 'document_symbols', uri = vim.env.VV_TEST_TMP .. '/missing.lua' }
    Managed.retain(50, true)
    assert(Managed.request('vv-mcp.lsp', params, 50).error.code == 'lsp_initializing')
    assert(Managed.prepare(function()
      vim.wait(100, function() return Expired > 0 end, 5)
      assert(Expired == 0, '预热期间不能回收')
      assert(Managed.request('vv-mcp.lsp', params, 50).error.code == 'lsp_initializing')
      return 1
    end) == 1)
    local result = Managed.request('vv-mcp.lsp', params, 50)
    assert(result.error.code == 'document_not_found', '预热结束后必须恢复真实请求分发')
    assert(vim.wait(300, function() return Expired == 1 end, 5), '预热结束后仍应按空闲租期回收')
  end)
end

T['预热失败后迟到的客户端可用时允许后续查询恢复'] = function()
  fixture()
  child.lua_func(function()
    local Managed = require('vv-mcp.managed')
    local params = { operation = 'workspace_symbols', uri = vim.env.VV_TEST_TMP, query = 'late' }
    Managed.start(200, true, {}, 30)
    local failure
    assert(vim.wait(100, function()
      failure = Managed.request('vv-mcp.lsp', params, 30)
      return failure.error and failure.error.code ~= 'lsp_initializing'
    end, 5))
    assert(failure.error.code == 'no_lsp')
    local get_clients = vim.lsp.get_clients
    vim.lsp.get_clients = function()
      return { {
        name = 'late_client',
        supports_method = function() return true end,
        request_sync = function() return { result = {} } end,
      } }
    end
    local result = Managed.request('vv-mcp.lsp', params, 30)
    vim.lsp.get_clients = get_clients
    assert(not result.error and result.results[1].client == 'late_client',
      '旧的预热失败不能永久阻挡已经就绪的客户端')
    Managed.stop()
  end)
end

T['未完成冷启动的实例在启动预算结束后自行退出'] = function()
  fixture()
  child.lua_func(function()
    assert(vim.wait(400, function() return Expired == 1 end, 5), 'broker 异常退出不能留下永久实例')
  end)
end

T['交互式 Neovim 不受托管保活控制'] = function()
  fixture()
  child.lua_func(function()
    vim.env.VV_MCP_MANAGED = nil
    require('vv-mcp.lifecycle').setup(Config)
    require('vv-mcp.managed').run(function() return true end, 1)
    vim.wait(200, function() return Expired > 0 end, 5)
    assert(Expired == 0, '不得关闭用户的交互式 Neovim')
  end)
end

return T
