-- 真实场景在独立子进程中执行；收集阶段仅注册具名用例。
local H = dofile(vim.env.VV_TEST_REPO .. '/tests/helpers.lua')
local T, child = H.new_set({ setup = 'minimal_init.lua' })

T["安装命令在途去重、错误通知与匹配版本复用"] = function()
  child.lua_func(function()
    -- :VVMcpInstall / :VVMcpUpdate 的开始提示与在途去重；Download.file 被替换，不发起真实下载

    local Download = require('vv-utils.download')
    local Fs = require('vv-utils.fs')
    local Version = require('vv-mcp.version')
    local tmp = vim.fn.tempname()

    local downloads = {}
    Download.file = function(opts, callback)
      downloads[#downloads + 1] = { url = opts.url, callback = callback }
      return function() end
    end

    local messages = {}
    vim.notify = function(message, level)
      messages[#messages + 1] = { message = message, level = level }
    end

    local function count(pattern)
      local n = 0
      for _, item in ipairs(messages) do
        if item.message:find(pattern, 1, true) then n = n + 1 end
      end
      return n
    end

    require('vv-mcp.commands').setup({ enabled = false, server = { install_dir = tmp } })

    local starting = ('vv-mcp: downloading server v%s…'):format(Version.version)

    vim.cmd('VVMcpInstall')
    assert(#downloads == 1, '未安装时应开始下载')
    assert(count(starting) == 1, '真正开始下载时提示一次：' .. vim.inspect(messages))

    vim.cmd('VVMcpUpdate')
    assert(#downloads == 1, '在途时重复执行不应并行下载')
    assert(count('already in progress') == 1, '在途时重复执行应提示：' .. vim.inspect(messages))

    downloads[1].callback({ ok = false, message = 'offline' })
    assert(count('Failed to download checksums') == 1, '下载失败应汇报结果')

    vim.cmd('VVMcpUpdate')
    assert(#downloads == 2 and count(starting) == 2, '上一次结束后应允许再次执行')
    downloads[2].callback({ ok = false, message = 'offline' })

    Fs.mkdir_p(tmp)
    Fs.write_all(vim.fs.joinpath(tmp, 'vv-mcp'), 'binary')
    Fs.write_all(vim.fs.joinpath(tmp, 'vv-mcp.version'), Version.version .. '\n')
    vim.cmd('VVMcpInstall')
    assert(#downloads == 2 and count(starting) == 2, '已是匹配版本时不下载也不提示开始')
    assert(messages[#messages].message:find('vv-mcp: server ' .. Version.version, 1, true), '已安装时直接汇报结果')

    Fs.delete(tmp)
  end)
end

return T
