-- 真实场景在独立子进程中执行；收集阶段仅注册具名用例。
local H = dofile(vim.env.VV_TEST_REPO .. '/tests/helpers.lua')
local T, child = H.new_set({ setup = 'minimal_init.lua' })

local function run(force_cleanup)
  child.lua_func(function(force_cleanup)
    local Download = require('vv-utils.download')
    local Fs = require('vv-utils.fs')
    local Binary = require('vv-mcp.binary')
    local Version = require('vv-mcp.version')

    local tmp = vim.fn.tempname()
    local old_dir = vim.fs.joinpath(tmp, 'old')
    local new_dir = vim.fs.joinpath(tmp, 'new')
    local disabled_dir = vim.fs.joinpath(tmp, 'disabled')
    local shared_dir = vim.fs.joinpath(tmp, 'shared')
    local old_started = vim.fs.joinpath(tmp, 'old-started')
    local disabled_started = vim.fs.joinpath(tmp, 'disabled-started')
    local shared_a_started = vim.fs.joinpath(tmp, 'shared-a-started')
    local shared_b_started = vim.fs.joinpath(tmp, 'shared-b-started')
    Fs.mkdir_p(tmp)

    local target = assert(Binary.target())
    local suffix = target:find('windows', 1, true) and '.exe' or ''
    local asset = 'vv-mcp-' .. target .. suffix
    local binary_content = 'fixture-binary'
    local checksum = vim.fn.sha256(binary_content)
    local blocking = {
      [old_dir] = old_started,
      [disabled_dir] = disabled_started,
    }
    local shared_asset_calls = 0
    local shared_checksums = {}
    local shared_binaries = {}

    local function download_artifacts(dir)
      local artifacts = {}
      if not Fs.exists(dir) then return artifacts end
      for name in vim.fs.dir(dir) do
        if name:match('%.download$') then artifacts[#artifacts + 1] = name end
      end
      return artifacts
    end

    local original_resolve = Download.resolve
    Download.resolve = function()
      return {
        name = 'fixture',
        command = '/bin/sh',
        build = function(_, url, destination)
          local install_dir = vim.fs.dirname(destination)
          if url:match('/checksums%.sha256$') then
            if install_dir == shared_dir then
              shared_checksums[#shared_checksums + 1] = destination
            end
            return {
              '/bin/sh',
              '-c',
              'printf "%s  %s\\n" "$1" "$2" > "$3"',
              '_',
              checksum,
              asset,
              destination,
            }
          end

          if install_dir == shared_dir then
            shared_asset_calls = shared_asset_calls + 1
            shared_binaries[#shared_binaries + 1] = destination
            if shared_asset_calls == 1 then
              return {
                '/bin/sh',
                '-c',
                [[
    printf partial > "$1"
    printf "%s" "$$" > "$2"
    trap 'sleep 0.25; exit 143' TERM
    while :; do sleep 0.05; done
    ]],
                '_',
                destination,
                shared_a_started,
              }
            end
            return {
              '/bin/sh',
              '-c',
              'printf "%s" "$1" > "$2"; printf "%s" "$$" > "$3"; sleep 0.6',
              '_',
              binary_content,
              destination,
              shared_b_started,
            }
          end

          local marker = blocking[install_dir]
          if marker then
            return {
              '/bin/sh',
              '-c',
              'printf "%s" "$$" > "$1"; exec sleep 10',
              '_',
              marker,
            }
          end
          return {
            '/bin/sh',
            '-c',
            'printf "%s" "$1" > "$2"',
            '_',
            binary_content,
            destination,
          }
        end,
      }
    end

    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message)
      notifications[#notifications + 1] = message
    end

    local mcp = require('vv-mcp')
    local fixture_pids = {}

    local function remember_pid(path)
      if not Fs.exists(path) then return end
      local ok, content = pcall(Fs.read_all, path)
      local pid = ok and tonumber(vim.trim(content or '')) or nil
      if pid then fixture_pids[pid] = true end
    end

    local function all_fixture_processes_stopped()
      for pid in pairs(fixture_pids) do
        if vim.uv.kill(pid, 0) ~= nil then return false end
      end
      return true
    end

    local function stop_fixture_processes()
      for _, path in ipairs({
        old_started,
        disabled_started,
        shared_a_started,
        shared_b_started,
      }) do
        remember_pid(path)
      end

      for pid in pairs(fixture_pids) do pcall(vim.uv.kill, pid, 15) end
      if not vim.wait(2000, all_fixture_processes_stopped) then
        for pid in pairs(fixture_pids) do
          if vim.uv.kill(pid, 0) ~= nil then pcall(vim.uv.kill, pid, 9) end
        end
        vim.wait(1000, all_fixture_processes_stopped)
      end
      return all_fixture_processes_stopped()
    end

    local test_ok, test_error = xpcall(function()
      mcp.setup({
        registry_dir = vim.fs.joinpath(tmp, 'registry-a'),
        server = { auto_install = true, install_dir = old_dir },
      })
      assert(vim.wait(3000, function() return Fs.exists(old_started) end),
        '旧配置未进入二进制下载')

      mcp.setup({
        registry_dir = vim.fs.joinpath(tmp, 'registry-b'),
        server = { auto_install = true, install_dir = new_dir },
      })
      assert(vim.wait(3000, function() return Binary.status({ install_dir = new_dir }).ready end),
        '新 setup 应完成各自的自动安装')
      assert(not Fs.exists(Binary.path({ install_dir = old_dir })),
        '重配不应安装旧二进制')
      assert(not Fs.exists(Binary.path({ install_dir = old_dir }) .. '.version'),
        '重配不应写入旧版本文件')
      assert(#download_artifacts(old_dir) == 0,
        '重配应清理旧安装临时文件')
      assert(#notifications == 1
        and notifications[1] == 'vv-mcp: installed server ' .. Version.version,
        '仅当前不同目录的 setup 可发布通知')
      notifications = {}

      mcp.setup({
        registry_dir = vim.fs.joinpath(tmp, 'registry-shared-a'),
        server = { auto_install = true, install_dir = shared_dir },
      })
      assert(vim.wait(3000, function() return Fs.exists(shared_a_started) end),
        '共享安装 A 未进入其延迟二进制下载')
      local a_pid = tonumber(vim.trim(Fs.read_all(shared_a_started) or ''))
      assert(a_pid, '共享安装 A 未发布其 shell 进程 PID')
      if force_cleanup then
        error('强制清理校验')
      end

      mcp.setup({
        registry_dir = vim.fs.joinpath(tmp, 'registry-shared-b'),
        server = { auto_install = true, install_dir = shared_dir },
      })
      assert(vim.wait(3000, function() return Fs.exists(shared_b_started) end),
        '共享安装 B 未在 A 退出前启动')
      assert(vim.uv.kill(a_pid, 0) ~= nil,
        '共享安装 A 在 B 进入下载前已退出')
      assert(vim.wait(3000, function() return Binary.status({ install_dir = shared_dir }).ready end),
        '共享安装 B 在 A 被取消后应保持就绪')
      assert(vim.wait(3000, function() return vim.uv.kill(a_pid, 0) == nil end),
        '已取消的共享安装 A 未终止其真实 shell 进程')
      assert(#notifications == 1
        and notifications[1] == 'vv-mcp: installed server ' .. Version.version,
        '已取消的共享 setup A 应保持静默，仅 setup B 可通知')
      assert(#shared_checksums == 2 and shared_checksums[1] ~= shared_checksums[2],
        '并发安装应使用不同校验和路径')
      assert(#shared_binaries == 2 and shared_binaries[1] ~= shared_binaries[2],
        '并发安装应使用不同二进制临时路径')
      assert(Fs.read_all(Binary.path({ install_dir = shared_dir })) == binary_content,
        '已取消的 A 清理污染了 B 的最终二进制')
      assert(Fs.read_all(Binary.path({ install_dir = shared_dir }) .. '.version')
        == Version.version .. '\n',
        '并发安装应保持最终版本路径固定')
      assert(#download_artifacts(shared_dir) == 0,
        '并发安装应清理所有归属下载产物')
      notifications = {}

      mcp.setup({
        registry_dir = vim.fs.joinpath(tmp, 'registry-c'),
        server = { auto_install = true, install_dir = disabled_dir },
      })
      assert(vim.wait(3000, function() return Fs.exists(disabled_started) end),
        '禁用 fixture 未进入二进制下载')
      mcp.setup({
        enabled = false,
        registry_dir = vim.fs.joinpath(tmp, 'registry-c'),
        server = { auto_install = true, install_dir = disabled_dir },
      })
      vim.wait(100)
      assert(not Fs.exists(Binary.path({ install_dir = disabled_dir })),
        '禁用 setup 不应安装进行中的二进制')
      assert(not Fs.exists(Binary.path({ install_dir = disabled_dir }) .. '.version'),
        '禁用 setup 不应写入进行中的版本文件')
      assert(#download_artifacts(disabled_dir) == 0,
        '禁用 setup 应清理进行中的临时文件')
      assert(#notifications == 0, '禁用 setup 不应发布自动安装通知')
    end, debug.traceback)

    pcall(mcp.setup, {
      enabled = false,
      registry_dir = vim.fs.joinpath(tmp, 'registry-cleanup'),
      server = { auto_install = false, install_dir = shared_dir },
    })
    local processes_stopped = stop_fixture_processes()
    vim.notify = original_notify
    Download.resolve = original_resolve
    pcall(Fs.delete, tmp)

    if force_cleanup then
      assert(not test_ok and tostring(test_error):find('强制清理校验', 1, true),
        '清理校验未在预期边界失败')
      assert(Download.resolve == original_resolve and vim.notify == original_notify,
        '清理校验未恢复测试替身')
      assert(processes_stopped, '清理校验保留了测试进程')
      assert(not Fs.exists(tmp), '清理校验保留了测试目录')

      return
    end

    if not processes_stopped and test_ok then
      test_ok = false
      test_error = 'fixture 清理保留了进程'
    end
    if not test_ok then error(test_error, 0) end
  end, force_cleanup)
end

T['自动安装重配与禁用取消真实模拟下载并清理产物'] = function() run(false) end
T['下载中断言失败仍恢复边界并终止真实模拟进程'] = function() run(true) end

return T
