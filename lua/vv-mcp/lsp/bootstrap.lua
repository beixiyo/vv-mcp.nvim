---目录冷启动：候选文件保留至受管实例退出，维持客户端索引生命周期
local Fix = require('vv-utils.lsp.fix')
local Async = require('vv-utils.async')

local M = {}
local max_attempts = 3

local function executable(config)
  local cmd = config.cmd
  if type(cmd) == 'function' or cmd == nil then return true end
  local program = type(cmd) == 'table' and cmd[1] or cmd
  return type(program) == 'string' and vim.fn.executable(program) == 1
end

---同一预算内按配置与文件类型各选择至多三个候选，只有初始化成功才算成功
---文件加载后出让事件循环，让原生 FileType/root_dir 启动流程执行；不代理用户配置
---@param paths string[] 遵守 ignore 规则的普通文件候选
---@param timeout_ms integer 剩余冷启动预算
---@return integer ready 已初始化且挂载到候选文件的客户端数量
function M.prepare(paths, timeout_ms)
  local deadline = vim.uv.hrtime() + timeout_ms * 1e6
  local configs = vim.tbl_filter(executable, Fix.config_snapshot())
  local attempts, buffers = {}, {}

  local function remaining()
    return math.max(0, math.floor((deadline - vim.uv.hrtime()) / 1e6))
  end

  local function clients()
    local ready = {}
    for _, client in ipairs(vim.lsp.get_clients()) do
      for bufnr in pairs(buffers) do
        if vim.lsp.buf_is_attached(bufnr, client.id) then
          ready[client.name] = ready[client.name] or {}
          ready[client.name][vim.bo[bufnr].filetype] = true
        end
      end
    end
    return ready
  end

  local finished, leaving, outcome = false, false, nil
  local exit_hook = vim.api.nvim_create_autocmd('VimLeavePre', {
    once = true,
    callback = function() leaving = true end,
  })

  local batch = Async.batch({
    items = paths,
    is_valid = function() return not finished and not leaving and remaining() > 0 end,
    on_done = function(result) outcome = result end,
    worker = function(path)
      local ready = clients()
      local filetype = Fix.detect_filetype(path)
      local matching = {}

      if filetype then
        for index, config in ipairs(configs) do
          local served = ready[config.name]
          local key = config.filetypes and filetype or '*'
          local count = attempts[index] and attempts[index][key] or 0
          if not (served and (served[filetype] or config.filetypes == nil)) and count < max_attempts
              and (config.filetypes == nil or vim.tbl_contains(config.filetypes, filetype)) then
            matching[#matching + 1] = { index = index, key = key }
          end
        end
      end

      -- 共享格式化器的额度不能否决其他语言服务器的候选
      -- FileType 仍由 Neovim 分发，已就绪或额度耗尽的配置可能顺带复用该文件
      if #matching > 0 then
        for _, match in ipairs(matching) do
          attempts[match.index] = attempts[match.index] or {}
          attempts[match.index][match.key] = (attempts[match.index][match.key] or 0) + 1
        end

        local bufnr = vim.fn.bufadd(path)
        local ok = pcall(vim.fn.bufload, bufnr)

        if ok and vim.api.nvim_buf_is_loaded(bufnr) then
          buffers[bufnr] = true
        elseif vim.api.nvim_buf_is_valid(bufnr) and not vim.bo[bufnr].modified then
          pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
      end
    end,
  })

  local ok, failure = pcall(vim.wait, remaining(), function() return outcome ~= nil or leaving end, 20)
  finished = true
  batch:cancel()
  pcall(vim.api.nvim_del_autocmd, exit_hook)

  if not ok then error(failure, 0) end
  if outcome and #outcome.errors > 0 then error(outcome.errors[1].err, 0) end
  if leaving or not next(buffers) then return 0 end

  vim.wait(remaining(), function()
    if next(clients()) == nil then return false end
    for _, client in ipairs(vim.lsp.get_clients({ _uninitialized = true })) do
      if not client.initialized then
        for bufnr in pairs(buffers) do
          if vim.lsp.buf_is_attached(bufnr, client.id) then return false end
        end
      end
    end
    return true
  end, 20)
  local ready = clients()
  return vim.tbl_count(ready)
end

return M
