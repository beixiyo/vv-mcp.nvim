-- 真实场景在独立子进程中执行；收集阶段仅注册具名用例。
local H = dofile(vim.env.VV_TEST_REPO .. '/tests/helpers.lua')
local T, child = H.new_set({ setup = 'minimal_init.lua' })

T["重命名预览不写盘且应用一次性事务完整读回"] = function()
  child.lua_func(function()
    local Fs = require('vv-utils.fs')
    local Rename = require('vv-mcp.lsp.rename')
    local tmp = vim.fn.tempname()
    local path = vim.fs.joinpath(tmp, 'fixture.ts')
    local uri = vim.uri_from_fname(path)

    Fs.mkdir_p(tmp)
    Fs.write_all(path, 'export const oldName = 1\n')
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)

    local client = {
      id = 902,
      name = 'fixture-lsp',
      offset_encoding = 'utf-16',
      supports_method = function() return true end,
      request_sync = function(_, method)
        assert(method == 'textDocument/rename')
        return { result = { changes = { [uri] = {{
          range = { start = { line = 0, character = 13 }, ['end'] = { line = 0, character = 20 } },
          newText = 'newName',
        }} } } }
      end,
    }

    local function context(params)
      return {
        params = params,
        path = path,
        bufnr = bufnr,
        timeout_ms = 1000,
        clients = { client },
      }
    end

    local preview = Rename.request(context({
      line = 1,
      character = 14,
      newName = 'newName',
    }), {
      name = 'rename_preview',
      method = 'textDocument/rename',
    })
    assert(not preview.error, vim.inspect(preview.error))
    assert(preview.filesChanged == 1 and preview.editsCount == 1)
    assert(Fs.read_all(path) == 'export const oldName = 1\n', 'preview 不应改动文件')

    local applied = Rename.request(context({ renameId = preview.renameId }), {
      name = 'rename_apply',
    })
    assert(applied.applied and applied.saved, vim.inspect(applied))
    assert(Fs.read_all(path) == 'export const newName = 1\n')

    local replay = Rename.request(context({ renameId = preview.renameId }), {
      name = 'rename_apply',
    })
    assert(replay.error and replay.error.code == 'rename_not_found')

    Fs.delete(tmp)
  end)
end

return T
