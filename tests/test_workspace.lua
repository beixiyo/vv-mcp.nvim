-- 真实场景在独立子进程中执行；收集阶段仅注册具名用例。
local H = dofile(vim.env.VV_TEST_REPO .. '/tests/helpers.lua')
local T, child = H.new_set({ setup = 'minimal_init.lua' })

T["工作区资源事务预检、单次应用与客户端编辑合并"] = function()
  child.lua_func(function()
    local Fs = require('vv-utils.fs')
    local Workspace = require('vv-mcp.workspace')
    local tmp = vim.fn.tempname()
    local previous_cwd = vim.fn.getcwd()

    Fs.mkdir_p(tmp)
    vim.fn.chdir(tmp)
    vim.uv.chdir(tmp)

    local special_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(special_buf, 'vv-git:/panel/release-test')
    vim.api.nvim_buf_set_lines(special_buf, 0, -1, false, { 'special buffer' })

    local source = vim.fs.joinpath(tmp, 'source.ts')
    local target = vim.fs.joinpath(tmp, 'renamed.ts')
    Fs.write_all(source, 'export const value = 1\n')
    vim.api.nvim_buf_set_name(0, source)

    local preview = Workspace.request({
      operation = 'rename_resource_preview',
      oldUri = source,
      newUri = target,
    })
    assert(not preview.error, vim.inspect(preview.error))
    assert(preview.resourceRenameId, 'preview 应返回 resourceRenameId')
    assert(Fs.exists(source), 'preview 不应移动 source 文件')
    assert(not Fs.exists(target), 'preview 不应创建目标文件')

    local applied = Workspace.request({
      operation = 'rename_resource_apply',
      resourceRenameId = preview.resourceRenameId,
    })
    assert(applied.applied == true, vim.inspect(applied))
    assert(not Fs.exists(source), '应用应删除旧路径')
    assert(Fs.exists(target), '应用应创建目标路径')
    assert(Fs.read_all(target) == 'export const value = 1\n', '应用应保留文件内容')

    local replay = Workspace.request({
      operation = 'rename_resource_apply',
      resourceRenameId = preview.resourceRenameId,
    })
    assert(replay.error.code == 'resource_rename_not_found', '已应用事务应为一次性')

    local modified_source = vim.fs.joinpath(tmp, 'modified.ts')
    local modified_target = vim.fs.joinpath(tmp, 'modified-renamed.ts')
    Fs.write_all(modified_source, 'export const modified = false\n')
    local modified_buf = vim.fn.bufadd(modified_source)
    vim.fn.bufload(modified_buf)
    vim.api.nvim_buf_set_lines(modified_buf, 0, -1, false, { 'export const modified = true' })
    local modified_preview = Workspace.request({
      operation = 'rename_resource_preview',
      oldUri = modified_source,
      newUri = modified_target,
    })
    assert(modified_preview.error.code == 'resource_buffer_modified', '已修改的源码缓冲应阻止 preview')
    vim.api.nvim_buf_delete(modified_buf, { force = true })

    local stale_source = vim.fs.joinpath(tmp, 'stale.ts')
    local stale_target = vim.fs.joinpath(tmp, 'stale-renamed.ts')
    Fs.write_all(stale_source, 'export const stale = 1\n')
    local stale_preview = Workspace.request({
      operation = 'rename_resource_preview',
      oldUri = stale_source,
      newUri = stale_target,
    })
    Fs.write_all(stale_target, 'occupied\n')
    local stale_apply = Workspace.request({
      operation = 'rename_resource_apply',
      resourceRenameId = stale_preview.resourceRenameId,
    })
    assert(stale_apply.error.code == 'resource_rename_stale', '目标冲突应使 preview 失效')
    assert(Fs.exists(stale_source), '过期应用不应移动 source 文件')

    local lsp_source = vim.fs.joinpath(tmp, 'module.ts')
    local lsp_target = vim.fs.joinpath(tmp, 'module-renamed.ts')
    local consumer = vim.fs.joinpath(tmp, 'consumer.ts')
    local before_import = "import { value } from './module'"
    local after_import = "import { value } from './module-renamed'"
    Fs.write_all(lsp_source, 'export const value = 2\n')
    Fs.write_all(consumer, before_import .. '\n')
    local source_buf = vim.fn.bufadd(lsp_source)
    vim.fn.bufload(source_buf)
    local target_ghost = vim.fn.bufadd(lsp_target)
    vim.fn.bufload(target_ghost)
    assert(vim.api.nvim_buf_line_count(target_ghost) == 1, 'fixture 目标应是空 ghost buffer')

    local notified = false
    local original_get_clients = vim.lsp.get_clients
    vim.lsp.get_clients = function()
      return {{
        name = 'fixture-lsp',
        offset_encoding = 'utf-16',
        server_capabilities = {
          workspace = { fileOperations = { willRename = {}, didRename = {} } },
        },
        request_sync = function(_, method)
          assert(method == 'workspace/willRenameFiles')
          return {
            result = {
              changes = {
                [vim.uri_from_fname(consumer)] = {{
                  range = {
                    start = { line = 0, character = 0 },
                    ['end'] = { line = 0, character = #before_import },
                  },
                  newText = after_import,
                }},
              },
            },
          }
        end,
        notify = function(_, method)
          assert(method == 'workspace/didRenameFiles')
          notified = true
        end,
        stop = function() end,
      }}
    end

    local lsp_preview = Workspace.request({
      operation = 'rename_resource_preview',
      oldUri = lsp_source,
      newUri = lsp_target,
    })
    assert(lsp_preview.editsCount == 1, 'preview 应包含 LSP 的 import 编辑')
    assert(Fs.read_all(consumer) == before_import .. '\n', 'preview 不应直接应用 import 编辑')

    local lsp_applied = Workspace.request({
      operation = 'rename_resource_apply',
      resourceRenameId = lsp_preview.resourceRenameId,
    })
    assert(lsp_applied.applied == true, vim.inspect(lsp_applied))
    assert(Fs.exists(lsp_target), 'LSP 感知的 apply 应重命名源文件')
    assert(Fs.read_all(consumer) == after_import .. '\n', 'LSP 感知的 apply 应保存 import 编辑')
    assert(notified, 'apply 应发送 workspace/didRenameFiles')
    assert(not vim.api.nvim_buf_is_valid(target_ghost), '应用应移除空目标 ghost buffer')
    vim.lsp.get_clients = original_get_clients
    assert(
      vim.fn.resolve(vim.api.nvim_buf_get_name(source_buf)) == vim.fn.resolve(lsp_target),
      'apply 应同步源 buffer 路径'
    )

    vim.fn.chdir(previous_cwd)
    vim.uv.chdir(previous_cwd)
    Fs.delete(tmp)
  end)
end

return T
