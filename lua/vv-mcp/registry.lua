local Fs = require('vv-utils.fs')

local M = {}

---@param config VVMcpConfig
---@return string
function M.dir(config)
  return vim.fs.normalize(config.registry_dir)
end

---@param config VVMcpConfig
---@param instance VVMcpInstance
function M.write(config, instance)
  -- 按 pid 的临时实例文件，rename 已保证原子可见；不需要断电持久性，跳过 macOS 上数毫秒的 F_FULLSYNC
  Fs.save_json(M.path(config, instance.pid), instance, { fsync = false })
end

---@param config VVMcpConfig
---@param pid? integer
function M.remove(config, pid)
  local path = M.path(config, pid or vim.fn.getpid())
  if Fs.exists(path) then Fs.delete(path) end
end

---@param config VVMcpConfig
---@param pid integer
---@return string
function M.path(config, pid)
  return vim.fs.joinpath(M.dir(config), tostring(pid) .. '.json')
end

return M

