---受管 Neovim 自主管理保活；生命周期不再依附某一个 CLI/MCP broker
local Fs = require('vv-utils.fs')
local Instance = require('vv-mcp.instance')
local Registry = require('vv-mcp.registry')

local M = {}
local state

-- Rust 会传入归一化值；保留旧版 broker 启动受管实例时的环境变量默认值
local defaults = { idle = 300000, ready = 15000, handoff = 15000, watch = 1000 }

local function duration(name, fallback)
  local value = tonumber(vim.env[name])
  return value and value > 0 and math.floor(value) or fallback
end

local function now()
  return vim.uv.hrtime() / 1e6
end

local function renew(current, timeout_ms)
  current.expires = math.max(current.expires, now() + (timeout_ms or current.idle))
end

-- 路由根会随 :cd 改变，projectId 只标识最初身份，不能作为接管依据
local function normalized_root(path)
  local normalized = vim.fs.normalize(vim.uv.fs_realpath(path) or path):gsub('/+$', '')
  return vim.fn.has('win32') == 1 and normalized:lower() or normalized
end

local function covers_project(instance, current)
  if type(instance.roots) ~= 'table' then return false end
  for _, root in ipairs(instance.roots) do
    if type(root) == 'string' and root ~= '' then
      root = normalized_root(root)
      if current.root == root or current.root:sub(1, #root + 1) == root .. '/' then
        return true
      end
    end
  end
  return false
end

local function interactive_candidates(current)
  local candidates = {}
  local directory = Registry.dir(current.config)
  if not vim.uv.fs_stat(directory) then return candidates end
  for name, kind in vim.fs.dir(directory) do
    if kind == 'file' and name:match('%.json$') then
      local ok, instance = pcall(Fs.load_json, vim.fs.joinpath(directory, name))
      if ok and type(instance) == 'table' and instance.kind == 'interactive' and covers_project(instance, current)
          and type(instance.pid) == 'number' and type(instance.socket) == 'string'
          and instance.socket ~= '' and vim.uv.kill(instance.pid, 0) then
        candidates[#candidates + 1] = instance
      end
    end
  end
  return candidates
end

-- 仅发现同项目交互式记录时才启动探测。使用原生 remote-expr 异步验证，
-- 不在主线程 rpcrequest，也不把 PID 存活或 socket 文件存在当作接管成功
local function verify_interactive(current, done)
  local candidates = interactive_candidates(current)
  local index = 0

  local function next_candidate()
    if state ~= current then return end
    index = index + 1
    local instance = candidates[index]
    if not instance then return done(false) end

    local ok, process = pcall(vim.system, {
      vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE',
      '--server', instance.socket, '--remote-expr',
      [[luaeval("vim.json.encode(require('vv-mcp.instance').current())")]],
    }, { text = true, timeout = 3000 }, vim.schedule_wrap(function(result)
      if state ~= current then return end
      current.probe = nil
      local decoded, peer = pcall(vim.json.decode, result.stdout or '')
      if result.code == 0 and decoded and type(peer) == 'table'
          and peer.pid == instance.pid and peer.kind == 'interactive'
          and covers_project(peer, current) then
        done(true)
      else
        next_candidate()
      end
    end))
    if ok then current.probe = process else next_candidate() end
  end
  next_candidate()
end

---关闭本模块的计时器；可重复调用，不主动退出交互式或受管实例
function M.stop()
  local current = state
  state = nil
  if not current then return end
  if current.probe then current.probe:kill(15) end
  current.timer:stop()
  if not current.timer:is_closing() then current.timer:close() end
end

---建立受管实例自己的回收计时器；普通交互式 Neovim 不启用
---@param config VVMcpConfig
function M.setup(config)
  M.stop()
  if vim.env.VV_MCP_MANAGED ~= '1' or not config.enabled then return end
  local current = {
    config = config,
    root = normalized_root(Instance.current().roots[1]),
    idle = duration('VV_MCP_MANAGED_IDLE_TIMEOUT_MS', defaults.idle),
    startup_deadline = now() + duration('VV_MCP_MANAGED_READY_TIMEOUT_MS', defaults.ready),
    handoff_delay = duration('VV_MCP_MANAGED_HANDOFF_DELAY_MS', defaults.handoff),
    expires = 0,
    active = 0,
    retained = false,
    preparing = true,
    timer = assert(vim.uv.new_timer()),
  }

  state = current
  local interval = duration('VV_MCP_MANAGED_WATCH_INTERVAL_MS', defaults.watch)

  current.timer:start(interval, interval, vim.schedule_wrap(function()
    if state ~= current then return end
    local time = now()
    local expired = time >= (current.retained and current.expires or current.startup_deadline)
    if current.active == 0 and expired then
      M.stop()
      vim.cmd('silent! qa!')
      return
    end
    if current.retained and not current.probing then
      current.probing = true
      verify_interactive(current, function(found)
        if state ~= current then return end
        current.probing = false
        if not found then current.handoff_started = nil; return end
        current.handoff_started = current.handoff_started or now()
        if current.active == 0 and now() - current.handoff_started >= current.handoff_delay then
          M.stop()
          vim.cmd('silent! qa!')
        end
      end)
    end
  end))
end

---冷启动成功后交给实例自行保活；首次激活不把启动宽限期算作空闲租期
---@param timeout_ms integer 调用者请求的保活毫秒数
---@param preparing? boolean 是否仍需完成目录预热
---@return boolean
function M.retain(timeout_ms, preparing)
  if not state then error('Managed Neovim lifecycle is not initialized') end
  if not state.retained then state.expires = 0 end
  state.retained = true
  state.preparing = preparing == true
  renew(state, timeout_ms)
  return true
end

---注册成功后原子地启用保活并排入目录预热，避免 CLI 取消留下永久 preparing 状态
---@param timeout_ms integer 调用者保活毫秒数
---@param preparing boolean 是否需要目录预热
---@param paths string[] 目录候选
---@param ready_timeout_ms integer 剩余预热预算
---@return boolean
function M.start(timeout_ms, preparing, paths, ready_timeout_ms)
  M.retain(timeout_ms, preparing)
  local current = state
  if preparing then
    vim.schedule(function()
      if state ~= current then return end
      local ok, ready = pcall(M.prepare, function()
        return require('vv-mcp.lsp.bootstrap').prepare(paths, ready_timeout_ms)
      end)
      if not ok then
        current.preparation_error = tostring(ready)
      elseif ready == 0 then
        current.preparation_error = 'No workspace LSP client initialized; pass a source file as uri'
      end
    end)
  end
  return true
end

---所有 CLI/MCP 实例请求共用此入口；执行中禁止回收，完成或失败后续期
---@param callback fun(): any
---@param timeout_ms? integer 调用者保活毫秒数；较短租期不会缩短既有过期时间
---@return any
function M.run(callback, timeout_ms)
  local current = state
  if current then
    current.active = current.active + 1
    renew(current, timeout_ms)
  end
  local ok, result = pcall(callback)
  if current then
    current.active = current.active - 1
    renew(current, timeout_ms)
  end
  if not ok then error(result, 0) end
  return result
end

---目录预热独立于请求方连接；即使原 CLI 被取消，已开始的预热也可完成
---@param callback fun(): integer
---@return integer
function M.prepare(callback)
  local current = state
  if current then current.preparing = true end
  local ok, result = pcall(M.run, callback)
  if current then current.preparing = false end
  if not ok then error(result, 0) end
  return result
end

---统一实例 RPC 入口；其他调用者遇到目录预热时返回可重试状态，不启动第二份预热
---@param module string
---@param params table
---@param timeout_ms integer
---@return any
function M.request(module, params, timeout_ms)
  return M.run(function()
    if state and state.preparing and module == 'vv-mcp.lsp' then
      return { error = { code = 'lsp_initializing', message = 'Managed workspace LSP is initializing' } }
    end
    local result = require(module).request(params)
    if state and state.preparation_error and module == 'vv-mcp.lsp'
        and (params.operation == 'workspace_symbols' or params.operation == 'workspace_diagnostics') then
      if result.error then
        result.error.message = state.preparation_error .. ': ' .. (result.error.message or result.error.code)
      else
        -- 客户端可能在预热预算结束后才初始化；旧错误不能封死后续查询
        state.preparation_error = nil
      end
    end
    return result
  end, timeout_ms)
end

return M
