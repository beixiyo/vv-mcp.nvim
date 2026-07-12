local root = vim.fn.getcwd()
dofile(root .. '/tests/minimal_init.lua')

local Binary = require('vv-mcp.binary')
local Download = require('vv-utils.download')
local Fs = require('vv-utils.fs')
local tmp = vim.fn.tempname()

assert(Binary.target({ sysname = 'Darwin', machine = 'arm64' }) == 'aarch64-apple-darwin')
assert(Binary.target({ sysname = 'Darwin', machine = 'x86_64' }) == 'x86_64-apple-darwin')
assert(Binary.target({ sysname = 'Linux', machine = 'aarch64' }) == 'aarch64-unknown-linux-musl')
assert(Binary.target({ sysname = 'Linux', machine = 'x86_64' }) == 'x86_64-unknown-linux-musl')
assert(Binary.target({ sysname = 'Windows_NT', machine = 'AMD64' }) == 'x86_64-pc-windows-msvc')
assert(Binary.target({ sysname = 'FreeBSD', machine = 'x86_64' }) == nil)
assert(Binary.path({}) == vim.fs.normalize(vim.fn.expand('~/.local/bin/vv-mcp')))

local managed = { install_dir = tmp }
assert(Binary.path(managed) == vim.fs.joinpath(tmp, 'vv-mcp'))
local status = Binary.status(managed)
assert(status.managed == true and status.ready == false)

local custom = { path = '/custom/vv-mcp', auto_install = false }
assert(Binary.path(custom) == '/custom/vv-mcp')
assert(Binary.status(custom).managed == false)

local target = assert(Binary.target())
local suffix = target:find('windows', 1, true) and '.exe' or ''
local asset = 'vv-mcp-' .. target .. suffix
local release_dir = vim.fs.joinpath(tmp, 'release')
local fake_bin = vim.fs.joinpath(tmp, 'fake-bin')
Fs.mkdir_p(release_dir)
Fs.mkdir_p(fake_bin)
local binary_content = 'fixture-binary\0content'
local binary_file = assert(io.open(vim.fs.joinpath(release_dir, asset), 'wb'))
binary_file:write(binary_content)
binary_file:close()
Fs.write_all(
  vim.fs.joinpath(release_dir, 'checksums.sha256'),
  vim.fn.sha256(binary_content) .. '  ' .. asset .. '\n'
)
local fake_curl = vim.fs.joinpath(fake_bin, 'curl')
Fs.write_all(fake_curl, [[#!/bin/sh
set -eu
output=''
url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
cp "$VV_MCP_TEST_RELEASE/$(basename "$url")" "$output"
]])
vim.uv.fs_chmod(fake_curl, 493)
local original_path = vim.env.PATH
local original_resolve = Download.resolve
vim.env.PATH = fake_bin .. ':' .. original_path
vim.env.VV_MCP_TEST_RELEASE = release_dir

local install_result
Binary.install(managed, {}, function(result) install_result = result end)
assert(vim.wait(5000, function() return install_result ~= nil end), 'binary install timed out')
assert(install_result.ok and install_result.changed, vim.inspect(install_result))
assert(Fs.read_all(Binary.path(managed)) == binary_content, 'installed binary must match release asset')
assert(Binary.status(managed).ready == true, 'installed version should be ready')

local ensure_result
Binary.ensure(managed, function(result) ensure_result = result end)
assert(vim.wait(1000, function() return ensure_result ~= nil end), 'binary ensure timed out')
assert(ensure_result.ok and ensure_result.changed == false, 'matching installation should be reused')
assert(Binary.uninstall(managed) == true, 'managed installation should be removable')
assert(Binary.status(managed).ready == false, 'uninstalled binary should not be ready')

Download.resolve = function() return nil end
local missing_downloader_result
Binary.install(managed, {}, function(result) missing_downloader_result = result end)
assert(missing_downloader_result and missing_downloader_result.ok == false)
assert(missing_downloader_result.message:find('curl', 1, true))
Download.resolve = original_resolve

vim.env.PATH = original_path
vim.env.VV_MCP_TEST_RELEASE = nil
Fs.delete(tmp)

print('vv-mcp binary test: ok')
