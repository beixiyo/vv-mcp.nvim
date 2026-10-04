-- 每个具名用例独占 Neovim、cwd、HOME、XDG 与 /tmp；失败路径同样由父 hook 清理
local M = {}

function M.new_set(opts)
  opts = opts or {}
  local MiniTest = require('mini.test')
  local child = MiniTest.new_child_neovim()
  local root
  local keys = { 'HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME',
    'XDG_CACHE_HOME', 'XDG_RUNTIME_DIR', 'TMPDIR' }
  local function cleanup()
    local ok, err = pcall(function()
      if child.is_running() then
        local errors = child.lua_get('AsyncErrors')
        assert(#errors == 0, '异步回调异常：' .. table.concat(errors, '\n'))
      end
    end)
    -- 父进程兜底读取本 case 的模拟下载 PID；RPC 异常或断言失败也不留下外部进程。
    local pids = {}
    local function collect_pids(path)
      local stat = vim.uv.fs_lstat(path)
      if not stat then return end
      if stat.type == 'directory' then
        for name in vim.fs.dir(path) do collect_pids(path .. '/' .. name) end
      elseif stat.type == 'file' and path:match('%-started$') then
        local file = assert(io.open(path, 'r'))
        local pid = tonumber(file:read('*a'))
        file:close()
        if pid then pids[pid] = true end
      end
    end
    if root then collect_pids(root) end
    for pid in pairs(pids) do
      if vim.uv.kill(pid, 0) then vim.uv.kill(pid, 15) end
    end
    local function stopped_processes()
      for pid in pairs(pids) do if vim.uv.kill(pid, 0) then return false end end
      return true
    end
    if not vim.wait(2000, stopped_processes, 10) then
      for pid in pairs(pids) do if vim.uv.kill(pid, 0) then vim.uv.kill(pid, 9) end end
    end
    local processes_stopped = vim.wait(2000, stopped_processes, 10)
    local stopped, stop_err = pcall(child.stop)
    if root then
      -- 恢复 fixture 目录权限，防止拒绝访问场景阻止失败清理
      local function unlock(path)
        local stat = vim.uv.fs_lstat(path)
        if not stat or stat.type ~= 'directory' then return end
        assert(vim.uv.fs_chmod(path, 493))
        for name in vim.fs.dir(path) do unlock(path .. '/' .. name) end
      end
      unlock(root)
      assert(vim.fn.delete(root, 'rf') == 0, '清理 fixture 失败：' .. root)
      root = nil
    end
    assert(stopped, stop_err)
    assert(processes_stopped, '模拟下载进程未完全停止')
    assert(ok, err)
  end
  local T = MiniTest.new_set({ hooks = {
    pre_case = function()
      root = assert(vim.uv.fs_mkdtemp('/tmp/vv-test-case-XXXXXX'))
      local saved, cwd = {}, vim.fn.getcwd()
      for _, key in ipairs(keys) do saved[key] = vim.env[key] end
      local started, err = pcall(function()
        for _, key in ipairs(keys) do
          local path = root .. '/' .. key:lower()
          vim.fn.mkdir(path, 'p')
          vim.env[key] = path
        end
        vim.cmd.cd(vim.fn.fnameescape(root))
        child.start({ '-u', 'NONE', '-i', 'NONE' }, { nvim_executable = vim.v.progpath })
      end)
      for _, key in ipairs(keys) do vim.env[key] = saved[key] end
      vim.cmd.cd(vim.fn.fnameescape(cwd))
      assert(started, err)
      child.lua_func(function(path, options)
        AsyncErrors = {}
        vim.env.VV_TEST_TMP = path
        vim.opt.runtimepath:prepend(vim.env.VV_UTILS)
        vim.opt.runtimepath:prepend(vim.env.VV_TEST_REPO)
        local schedule = vim.schedule
        vim.schedule = function(callback)
          schedule(function()
            local ok, err = xpcall(callback, debug.traceback)
            if not ok then AsyncErrors[#AsyncErrors + 1] = tostring(err) end
          end)
        end
        if options.setup then dofile(vim.env.VV_TEST_REPO .. '/tests/' .. options.setup) end
      end, root, opts)
    end,
    post_case = cleanup,
  } })
  return T, child
end

return M
