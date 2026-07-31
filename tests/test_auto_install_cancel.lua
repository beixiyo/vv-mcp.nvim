local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
dofile(root .. '/tests/minimal_init.lua')

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
    'old auto-install did not enter the binary download')

  mcp.setup({
    registry_dir = vim.fs.joinpath(tmp, 'registry-b'),
    server = { auto_install = true, install_dir = new_dir },
  })
  assert(vim.wait(3000, function() return Binary.status({ install_dir = new_dir }).ready end),
    'new setup should complete its own auto-install')
  assert(not Fs.exists(Binary.path({ install_dir = old_dir })),
    'reconfiguring must not install the old binary')
  assert(not Fs.exists(Binary.path({ install_dir = old_dir }) .. '.version'),
    'reconfiguring must not write the old version file')
  assert(#download_artifacts(old_dir) == 0,
    'reconfiguring must clean the old install temporary files')
  assert(#notifications == 1
      and notifications[1] == 'vv-mcp: installed server ' .. Version.version,
    'only the current different-directory setup may publish a notification')
  notifications = {}

  mcp.setup({
    registry_dir = vim.fs.joinpath(tmp, 'registry-shared-a'),
    server = { auto_install = true, install_dir = shared_dir },
  })
  assert(vim.wait(3000, function() return Fs.exists(shared_a_started) end),
    'shared install A did not enter its delayed binary download')
  local a_pid = tonumber(vim.trim(Fs.read_all(shared_a_started) or ''))
  assert(a_pid, 'shared install A did not publish its shell pid')
  if vim.env.VV_MCP_TEST_FORCE_CLEANUP == '1' then
    error('forced cleanup verification')
  end

  mcp.setup({
    registry_dir = vim.fs.joinpath(tmp, 'registry-shared-b'),
    server = { auto_install = true, install_dir = shared_dir },
  })
  assert(vim.wait(3000, function() return Fs.exists(shared_b_started) end),
    'shared install B did not start before A exited')
  assert(vim.uv.kill(a_pid, 0) ~= nil,
    'shared install A exited before B entered its binary download')
  assert(vim.wait(3000, function() return Binary.status({ install_dir = shared_dir }).ready end),
    'shared install B must remain ready after cancelled A exits')
  assert(vim.wait(3000, function() return vim.uv.kill(a_pid, 0) == nil end),
    'cancelled shared install A did not terminate its real shell process')
  assert(#notifications == 1
      and notifications[1] == 'vv-mcp: installed server ' .. Version.version,
    'cancelled shared setup A must stay silent and only setup B may notify')
  assert(#shared_checksums == 2 and shared_checksums[1] ~= shared_checksums[2],
    'concurrent installs must use unique checksum paths')
  assert(#shared_binaries == 2 and shared_binaries[1] ~= shared_binaries[2],
    'concurrent installs must use unique binary temporary paths')
  assert(Fs.read_all(Binary.path({ install_dir = shared_dir })) == binary_content,
    'cancelled A cleanup corrupted B final binary')
  assert(Fs.read_all(Binary.path({ install_dir = shared_dir }) .. '.version')
      == Version.version .. '\n',
    'shared installs must keep the final version path fixed')
  assert(#download_artifacts(shared_dir) == 0,
    'shared installs left owned download artifacts behind')
  notifications = {}

  mcp.setup({
    registry_dir = vim.fs.joinpath(tmp, 'registry-c'),
    server = { auto_install = true, install_dir = disabled_dir },
  })
  assert(vim.wait(3000, function() return Fs.exists(disabled_started) end),
    'disabled fixture did not enter the binary download')
  mcp.setup({
    enabled = false,
    registry_dir = vim.fs.joinpath(tmp, 'registry-c'),
    server = { auto_install = true, install_dir = disabled_dir },
  })
  vim.wait(100)
  assert(not Fs.exists(Binary.path({ install_dir = disabled_dir })),
    'disabled setup must not install the in-flight binary')
  assert(not Fs.exists(Binary.path({ install_dir = disabled_dir }) .. '.version'),
    'disabled setup must not write an in-flight version file')
  assert(#download_artifacts(disabled_dir) == 0,
    'disabled setup must clean in-flight temporary files')
  assert(#notifications == 0, 'disabled setup must not publish an auto-install notification')
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

if vim.env.VV_MCP_TEST_FORCE_CLEANUP == '1' then
  assert(not test_ok and tostring(test_error):find('forced cleanup verification', 1, true),
    'cleanup verification did not fail at the intended boundary')
  assert(Download.resolve == original_resolve and vim.notify == original_notify,
    'cleanup verification did not restore mocks')
  assert(processes_stopped, 'cleanup verification left a fixture process')
  assert(not Fs.exists(tmp), 'cleanup verification left its fixture directory')
  print('vv-mcp auto-install failure cleanup test: ok')
  return
end

if not processes_stopped and test_ok then
  test_ok = false
  test_error = 'fixture cleanup left a process'
end
if not test_ok then error(test_error, 0) end
print('vv-mcp auto-install cancellation test: ok')
