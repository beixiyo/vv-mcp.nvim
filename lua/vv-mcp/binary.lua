---下载、校验并管理与插件版本匹配的 vv-mcp 预编译二进制
local Fs = require('vv-utils.fs')
local Download = require('vv-utils.download')
local Version = require('vv-mcp.version')

local M = {}

local function result_error(message)
  return { ok = false, message = message }
end

local function read_binary(path)
  local file, error = io.open(path, 'rb')
  if not file then return nil, error end
  local content = file:read('*a')
  file:close()
  return content
end

local function default_install_dir()
  return vim.fs.normalize(vim.fn.expand('~/.local/bin'))
end

local function executable_name()
  return vim.uv.os_uname().sysname == 'Windows_NT' and 'vv-mcp.exe' or 'vv-mcp'
end

local function version_path(config)
  return M.path(config) .. '.version'
end

local function expected_checksum(content, asset)
  for line in content:gmatch('[^\r\n]+') do
    local checksum, name = line:match('^(%x+)%s+%*?(.+)$')
    if name == asset then return checksum:lower() end
  end
end

local function replace_binary(temporary, destination)
  local backup = destination .. '.old'
  if Fs.exists(backup) then Fs.delete(backup) end
  if Fs.exists(destination) then
    local backed_up, backup_error = vim.uv.fs_rename(destination, backup)
    if not backed_up then return false, backup_error end
  end
  local replaced, replace_error = vim.uv.fs_rename(temporary, destination)
  if not replaced then
    if Fs.exists(backup) then vim.uv.fs_rename(backup, destination) end
    return false, replace_error
  end
  if Fs.exists(backup) then Fs.delete(backup) end
  return true
end

local function install_error(error)
  local detail = tostring(error)
  if vim.uv.os_uname().sysname == 'Windows_NT' then
    return table.concat({
      'Failed to replace vv-mcp.exe: ' .. detail,
      'If vv-mcp.exe is running, stop the MCP client or restart the application using it, then retry :VVMcpUpdate',
    }, '\n')
  end
  return 'Failed to install binary: ' .. detail
end

local function download(url, destination, callback)
  Download.file({ url = url, destination = destination, retries = 3 }, function(result)
    callback(result.ok, result.message, result)
  end)
end

---将系统信息转换为 GitHub Release 的 Rust target
---@param uname? table uv.os_uname() 兼容结构
---@return string? target
function M.target(uname)
  uname = uname or vim.uv.os_uname()
  local system = uname.sysname
  local machine = (uname.machine or ''):lower()
  local arm = machine == 'arm64' or machine == 'aarch64'
  local x64 = machine == 'x86_64' or machine == 'amd64'
  if system == 'Darwin' and arm then return 'aarch64-apple-darwin' end
  if system == 'Darwin' and x64 then return 'x86_64-apple-darwin' end
  if system == 'Linux' and arm then return 'aarch64-unknown-linux-musl' end
  if system == 'Linux' and x64 then return 'x86_64-unknown-linux-musl' end
  if system == 'Windows_NT' and x64 then return 'x86_64-pc-windows-msvc' end
end

---@param config? VVMcpServerConfig
---@return string path
function M.path(config)
  config = config or require('vv-mcp.config').get().server
  if config.path and config.path ~= '' then return vim.fs.normalize(config.path) end
  return vim.fs.joinpath(config.install_dir or default_install_dir(), executable_name())
end

---@param config? VVMcpServerConfig
---@return table status
function M.status(config)
  config = config or require('vv-mcp.config').get().server
  local path = M.path(config)
  local installed_version = Fs.exists(version_path(config))
      and vim.trim(Fs.read_all(version_path(config)) or '')
      or nil
  return {
    path = path,
    exists = Fs.exists(path),
    version = installed_version,
    expectedVersion = Version.version,
    target = M.target(),
    managed = not config.path,
    ready = Fs.exists(path) and (config.path ~= nil or installed_version == Version.version),
  }
end

---异步下载并安装当前插件版本对应的预编译二进制
---@param config VVMcpServerConfig
---@param opts? { force?: boolean }
---@param callback? fun(result: table)
function M.install(config, opts, callback)
  opts = opts or {}
  callback = callback or function() end
  if config.path then
    callback(result_error('server.path is user-managed; remove it before automatic installation'))
    return
  end
  local status = M.status(config)
  if status.ready and not opts.force then
    callback({ ok = true, changed = false, path = status.path, version = Version.version })
    return
  end
  local target = M.target()
  if not target then
    callback(result_error('Unsupported platform: ' .. vim.inspect(vim.uv.os_uname())))
    return
  end
  local install_dir = config.install_dir or default_install_dir()
  Fs.mkdir_p(install_dir)
  local suffix = target:find('windows', 1, true) and '.exe' or ''
  local asset = 'vv-mcp-' .. target .. suffix
  local base_url = ('https://github.com/%s/releases/download/v%s'):format(
    Version.repository,
    Version.version
  )
  local temporary = vim.fs.joinpath(install_dir, asset .. '.download')
  local checksum_file = vim.fs.joinpath(install_dir, 'checksums.sha256.download')
  if Fs.exists(temporary) then Fs.delete(temporary) end
  if Fs.exists(checksum_file) then Fs.delete(checksum_file) end

  download(base_url .. '/checksums.sha256', checksum_file, function(checksum_ok, checksum_error)
    if not checksum_ok then
      callback(result_error('Failed to download checksums: ' .. tostring(checksum_error)))
      return
    end
    download(base_url .. '/' .. asset, temporary, function(binary_ok, binary_error)
      if not binary_ok then
        Fs.delete(checksum_file)
        callback(result_error('Failed to download ' .. asset .. ': ' .. tostring(binary_error)))
        return
      end
      local checksum_content = Fs.read_all(checksum_file) or ''
      local expected = expected_checksum(checksum_content, asset)
      local binary, read_error = read_binary(temporary)
      local actual = binary and vim.fn.sha256(binary) or nil
      Fs.delete(checksum_file)
      if not expected or not actual or actual:lower() ~= expected then
        Fs.delete(temporary)
        callback(result_error(read_error or ('Checksum verification failed for ' .. asset)))
        return
      end
      if not suffix:find('exe', 1, true) then vim.uv.fs_chmod(temporary, 493) end
      local replaced, replace_error = replace_binary(temporary, status.path)
      if not replaced then
        Fs.delete(temporary)
        callback(result_error(install_error(replace_error)))
        return
      end
      Fs.write_all(version_path(config), Version.version .. '\n')
      callback({ ok = true, changed = true, path = status.path, version = Version.version })
    end)
  end)
end

---缺失或版本不匹配时安装二进制
---@param config VVMcpServerConfig
---@param callback? fun(result: table)
function M.ensure(config, callback)
  M.install(config, { force = false }, callback)
end

---@param config VVMcpServerConfig
---@return boolean removed
function M.uninstall(config)
  if config.path then return false end
  local path = M.path(config)
  local removed = false
  for _, candidate in ipairs({ path, version_path(config), path .. '.old' }) do
    if Fs.exists(candidate) then
      Fs.delete(candidate)
      removed = true
    end
  end
  return removed
end

return M
