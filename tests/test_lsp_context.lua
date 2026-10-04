-- 真实场景在独立子进程中执行；收集阶段仅注册具名用例。
local H = dofile(vim.env.VV_TEST_REPO .. '/tests/helpers.lua')
local T, child = H.new_set({ setup = 'minimal_init.lua' })

T["文档准备保护未保存内容并管理临时缓冲和冷启动客户端"] = function()
  child.lua_func(function()
    local Context = require('vv-mcp.lsp.context')
    local Fs = require('vv-utils.fs')
    local _, error = Context.create({ query = '' }, {
      name = 'workspace_symbols',
      requires_query = true,
    })

    assert(error.code == 'invalid_query', 'workspace_symbols 应拒绝空查询')

    local missing = vim.fs.joinpath(vim.fn.tempname(), 'missing.ts')
    local buffer_count = #vim.api.nvim_list_bufs()
    local _, missing_error = Context.create({ uri = missing }, {
      name = 'hover',
      method = 'textDocument/hover',
      scope = 'document',
    })

    assert(missing_error.code == 'document_not_found', '缺失文档应被拒绝')
    assert(#vim.api.nvim_list_bufs() == buffer_count, '缺失文档不应创建 ghost buffer')

    local unsupported_path = vim.fs.joinpath(vim.fn.tempname(), 'unsupported.bin')
    Fs.mkdir_p(vim.fs.dirname(unsupported_path))
    Fs.write_all(unsupported_path, 'binary fixture\n')
    local before_temporary = #vim.api.nvim_list_bufs()
    local Fix = require('vv-utils.lsp.fix')
    local original_wait = Fix.wait_for_clients
    local waits = 0
    Fix.wait_for_clients = function(...)
      waits = waits + 1
      return original_wait(...)
    end
    local _, unsupported_error = Context.create({
      uri = unsupported_path,
      cleanupTemporary = true,
      timeoutMs = 5000,
    }, {
      name = 'fix_document',
      method = 'textDocument/codeAction',
      scope = 'document',
      handler = 'code_actions',
      sync_from_disk = true,
    })
    assert(unsupported_error.code == 'no_lsp')
    assert(waits == 0, '无可用 LSP 的文件应在进入客户端等待前拒绝')
    Fix.wait_for_clients = original_wait
    assert(#vim.api.nvim_list_bufs() == before_temporary,
      '未支持的批处理不应留下临时 buffers')
    Fs.delete(vim.fs.dirname(unsupported_path))

    local tmp = vim.fn.tempname()
    local path = vim.fs.joinpath(tmp, 'external.ts')
    Fs.mkdir_p(tmp)
    Fs.write_all(path, 'before\n')
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    vim.uv.sleep(10)
    Fs.write_all(path, 'after external write\n')

    local _, no_lsp_error = Context.create({ uri = path }, {
      name = 'fix_document',
      method = 'textDocument/codeAction',
      scope = 'document',
      handler = 'code_actions',
      sync_from_disk = true,
    })
    assert(no_lsp_error.code == 'no_lsp')
    assert(vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == 'after external write',
      '自动修复应读取到最新的磁盘内容')

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'unsaved' })
    local _, modified_error = Context.create({ uri = path }, {
      name = 'fix_document',
      method = 'textDocument/codeAction',
      scope = 'document',
      handler = 'code_actions',
      sync_from_disk = true,
    })
    assert(modified_error.code == 'buffer_modified', '自动修复应保留未保存改动')
    Fs.delete(tmp)

    local cleanup_root = vim.fn.tempname()
    local cleanup_path = vim.fs.joinpath(cleanup_root, 'cleanup.ts')
    Fs.mkdir_p(cleanup_root)
    Fs.write_all(cleanup_path, 'export const value = 1\n')
    local original_get_clients = vim.lsp.get_clients
    vim.lsp.get_clients = function()
      return { {
        config = {},
        supports_method = function() return true end,
      } }
    end
    local before_cleanup = #vim.api.nvim_list_bufs()
    local cleanup_context, cleanup_error = Context.create({
      uri = cleanup_path,
      cleanupTemporary = true,
    }, {
      name = 'fix_document',
      method = 'textDocument/codeAction',
      scope = 'document',
      handler = 'code_actions',
      sync_from_disk = true,
    })
    assert(cleanup_context and not cleanup_error)
    assert(cleanup_context.temporary == true)
    Context.cleanup(cleanup_context)
    assert(#vim.api.nvim_list_bufs() == before_cleanup,
      '批量请求成功后应清理临时 buffer')
    vim.lsp.get_clients = original_get_clients
    Fs.delete(cleanup_root)

    --- 冷启动竞态：多个 LSP 同时连接，但初始化有先后
    --- 先完成握手的客户端不得让等待提前结束，否则晚初始化客户端的修复项会被整批漏掉
    local cold_root = vim.fn.tempname()
    local cold_path = vim.fs.joinpath(cold_root, 'cold.tsx')
    Fs.mkdir_p(cold_root)
    Fs.write_all(cold_path, 'export const cold = 1\n')

    local fix_operation = {
      name = 'fix_document',
      method = 'textDocument/codeAction',
      scope = 'document',
      handler = 'code_actions',
      sync_from_disk = true,
      wait_all_clients = true,
    }

    ---@param late_init_after integer? 第几次轮询后让晚到的客户端完成初始化；nil 表示永不完成
    local function stub_cold_start(late_init_after)
      local polls = 0
      local fast = { name = 'tsgo', initialized = true, supports_method = function() return true end }
      local slow = { name = 'tailwindcss', initialized = false, supports_method = function() return true end }

      vim.lsp.get_clients = function(filter)
        polls = polls + 1
        if late_init_after and polls > late_init_after then slow.initialized = true end

        local all = { fast, slow }
        if filter and filter._uninitialized then return all end
        return vim.tbl_filter(function(client) return client.initialized end, all)
      end
    end

    stub_cold_start(2)
    local cold_context = assert(Context.create({ uri = cold_path, timeoutMs = 2000 }, fix_operation))
    local cold_names = vim.tbl_map(function(client) return client.name end, cold_context.clients)
    table.sort(cold_names)
    assert(vim.deep_equal(cold_names, { 'tailwindcss', 'tsgo' }),
      '修复需等待全部已连接的客户端完成初始化，当前：' .. vim.inspect(cold_names))
    assert(#cold_context.pending_clients == 0, '已收敛客户端不应被报告为待处理')

    --- bufload 触发的 autocmd 可能在首次查询之后才创建客户端，临时 buffer 必须允许延迟连接
    local late_path = vim.fs.joinpath(cold_root, 'late.tsx')
    Fs.write_all(late_path, 'export const late = 1\n')
    local late_polls = 0
    local late_client = {
      name = 'tailwindcss',
      initialized = true,
      supports_method = function() return true end,
    }
    vim.lsp.get_clients = function(filter)
      if not filter or not filter.bufnr then return { late_client } end
      late_polls = late_polls + 1
      return late_polls >= 3 and { late_client } or {}
    end
    local late_context = assert(Context.create({ uri = late_path, timeoutMs = 500 }, fix_operation))
    assert(late_context.clients[1] == late_client,
      '临时 buffers 应等待 bufload 后创建的客户端')

    --- 超时仍未收敛时，不能静默当作「已修完」，必须报告缺失的客户端
    stub_cold_start(nil)
    local stalled_context = assert(Context.create({ uri = cold_path, timeoutMs = 60 }, fix_operation))
    assert(vim.deep_equal(stalled_context.pending_clients, { 'tailwindcss' }),
      '未收敛客户端应被报告，当前: ' .. vim.inspect(stalled_context.pending_clients))

    --- 非修复类操作不承诺穷尽，仍按「任一客户端可用即可」返回，避免拖慢交互请求
    stub_cold_start(nil)
    local hover_context = assert(Context.create({ uri = cold_path, timeoutMs = 2000 }, {
      name = 'hover',
      method = 'textDocument/hover',
      scope = 'document',
      handler = 'intelligence',
    }))
    assert(#hover_context.clients == 1 and hover_context.clients[1].name == 'tsgo',
      '交互操作不应在仍在初始化的客户端上阻塞')

    vim.lsp.get_clients = original_get_clients
    Fs.delete(cold_root)
  end)
end

return T
