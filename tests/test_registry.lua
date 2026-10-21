-- 真实场景在独立子进程中执行；收集阶段仅注册具名用例
local H = dofile(vim.env.VV_TEST_REPO .. '/tests/helpers.lua')
local T, child = H.new_set({ setup = 'minimal_init.lua' })

T["注册表写回、重配置、刷新、禁用与当前命令配置"] = function()
  child.lua_func(function()
    local tmp = vim.fn.tempname()
    require('vv-mcp').setup({
      registry_dir = tmp,
      server = { auto_install = false },
    })

    local Registry = require('vv-mcp.registry')
    local Instance = require('vv-mcp.instance')
    local instance = Instance.current()
    local path = Registry.path({ registry_dir = tmp }, instance.pid)

    assert(vim.uv.fs_stat(path), '注册表文件应存在')

    local data = vim.json.decode(require('vv-utils.fs').read_all(path))
    assert(data.pid == vim.fn.getpid(), '注册表 pid 应与 Neovim 一致')
    assert(data.instanceId:match(':' .. data.pid .. '$'), 'instance id 应包含 pid')
    assert(data.socket ~= '', '应发布 Neovim RPC socket')
    assert(data.cwd == vim.fs.normalize(vim.fn.getcwd()), 'cwd 应使用标准化 wire path')
    local root_is_absolute = data.roots[1]:sub(1, 1) == '/'
      or data.roots[1]:match('^%a:[/\\]') ~= nil
    assert(root_is_absolute, '注册表 roots 应使用绝对路径')
    assert(not data.projectId:match('^%.%-'), '项目 id 应使用根目录绝对 basename')

    local second_tmp = vim.fn.tempname()
    vim.api.nvim_exec_autocmds('FocusGained', {})
    require('vv-mcp').setup({
      registry_dir = second_tmp,
      server = { auto_install = false },
    })
    vim.wait(20)
    assert(not vim.uv.fs_stat(path), '重配置 registry_dir 时应移除旧注册表')

    local second_path = Registry.path({ registry_dir = second_tmp }, instance.pid)
    assert(vim.uv.fs_stat(second_path), '重配置 registry_dir 时应在新目录写入注册')
    Registry.remove({ registry_dir = second_tmp }, instance.pid)
    vim.cmd('VVMcpRefresh')
    assert(vim.uv.fs_stat(second_path), '重刷注册表应使用新的注册目录')
    assert(not vim.uv.fs_stat(path), '重刷注册表不应重建旧注册表')

    require('vv-mcp').setup({
      enabled = false,
      registry_dir = second_tmp,
      server = { auto_install = false },
    })
    vim.cmd('VVMcpRefresh')
    vim.wait(20)
    assert(not vim.uv.fs_stat(second_path), '禁用 setup 与 refresh 时应保持注册表不存在')

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
      '重配后安装命令应使用新的 server 配置')

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
    assert(ensure_calls == 0, '过期的定时自动安装不应使用旧配置')

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
      'LSP workspace folders 不应扩展实例项目范围')
    vim.lsp.get_clients = original_get_clients

    local invalid = require('vv-mcp.lsp').request({
      operation = 'definition',
      uri = '/tmp/example.lua',
      line = 0,
      character = 1,
    })
    assert(invalid.error.code == 'invalid_position', 'LSP 位置应为 1-based')

    local Operations = require('vv-mcp.lsp.operations')
    assert(Operations.get('workspace_symbols').requires_query, '查询 workspace symbols 时应提供 query')
    assert(not Operations.get('document_symbols').requires_position, '查询 document symbols 时不应要求 position')
    assert(Operations.get('type_definition').handler == 'navigation', '类型定义应走 navigation')

    Registry.remove({ registry_dir = tmp }, instance.pid)
    Registry.remove({ registry_dir = second_tmp }, instance.pid)
    require('vv-utils.fs').delete(tmp)
    require('vv-utils.fs').delete(second_tmp)
  end)
end

T["退出移除注册表后，迟到的 refresh 事件不应写回"] = function()
  child.lua_func(function()
    local tmp = vim.fn.tempname()
    require('vv-mcp').setup({
      registry_dir = tmp,
      server = { auto_install = false },
    })

    local Registry = require('vv-mcp.registry')
    local path = Registry.path({ registry_dir = tmp }, vim.fn.getpid())
    assert(vim.uv.fs_stat(path), '注册表文件应存在')

    -- 真实退出时 LSP 在 VimLeavePre 中被停止，LspDetach 晚于 remove 到达
    vim.api.nvim_exec_autocmds('VimLeavePre', { group = 'vv-mcp.lifecycle' })
    assert(not vim.uv.fs_stat(path), 'VimLeavePre 应移除注册表')

    vim.api.nvim_exec_autocmds('LspDetach', { group = 'vv-mcp.lifecycle' })
    vim.wait(20)
    assert(not vim.uv.fs_stat(path), '退出后的 LspDetach 不应重建注册表，否则每次退出都残留文件')

    require('vv-utils.fs').delete(tmp)
  end)
end

return T
