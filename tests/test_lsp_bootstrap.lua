local H = dofile(vim.env.VV_TEST_REPO .. '/tests/helpers.lua')
local T, child = H.new_set({ setup = 'minimal_init.lua' })

-- 使用 Neovim 原生配置、root_dir、挂载与初始化流程，仅替换外部 LSP transport
local function fixture()
  child.lua_func(function()
    vim.cmd('filetype on')
    Attempts = {}
    function Source(name, lines)
      local path = vim.env.VV_TEST_TMP .. '/' .. name
      require('vv-utils.fs').write_all(path, table.concat(lines or { '-- fixture' }, '\n') .. '\n')
      return path
    end
    function Server(name, filetypes, accept, delay)
      Attempts[name] = {}
      vim.lsp.config(name, {
        filetypes = filetypes,
        root_dir = function(bufnr, on_dir)
          local path = vim.api.nvim_buf_get_name(bufnr)
          Attempts[name][#Attempts[name] + 1] = path
          if accept and not path:find(accept, 1, true) then return end
          on_dir(vim.env.VV_TEST_TMP)
        end,
        cmd = function(dispatchers)
          local closing = false
          local id = 0
          return {
            request = function(method, _, callback)
              id = id + 1
              if method == 'initialize' then
                vim.defer_fn(function()
                  if not closing then callback(nil, { capabilities = { workspaceSymbolProvider = true } }) end
                end, delay or 0)
              else
                callback(nil, nil)
              end
              return true, id
            end,
            notify = function() return true end,
            is_closing = function() return closing end,
            terminate = function()
              if closing then return end
              closing = true
              dispatchers.on_exit(0, 0)
            end,
          }
        end,
      })
      vim.lsp.enable(name)
    end
  end)
end

T['首个候选被拒绝后继续尝试且保持当前窗口'] = function()
  fixture()
  child.lua_func(function()
    local paths = { Source('a.lua'), Source('b.lua'), Source('c.lua') }
    Server('review_lua', { 'lua' }, 'b.lua')
    local current = vim.api.nvim_get_current_buf()
    assert(require('vv-mcp.lsp.bootstrap').prepare(paths, 500) == 1, '第二个候选应成功初始化')
    assert(#Attempts.review_lua >= 2, '不能因首个文件加载成功就跳过后续候选')
    assert(vim.api.nvim_get_current_buf() == current, '不能切换当前窗口的 buffer')
  end)
end

T['每个配置最多三个候选且全部拒绝时返回失败'] = function()
  fixture()
  child.lua_func(function()
    Server('review_lua', { 'lua' }, 'never')
    Server('review_python', { 'python' }, 'never')
    local paths = { Source('README.md') }
    for i = 1, 4 do
      paths[#paths + 1] = Source(i .. '.lua')
      paths[#paths + 1] = Source(i .. '.py')
    end
    assert(require('vv-mcp.lsp.bootstrap').prepare(paths, 300) == 0, '加载成功不能冒充客户端成功')
    assert(#Attempts.review_lua == 3, 'Lua 配置最多尝试三个文件')
    assert(#Attempts.review_python == 3, 'Python 应有独立的三次额度')
    assert(vim.fn.bufloaded(paths[1]) == 0, '不匹配的 README 不应加载或计数')
  end)
end

T['共享配置耗尽候选额度后仍启动后续语言并等待其初始化'] = function()
  fixture()
  child.lua_func(function()
    Server('review_shared', { 'markdown', 'typescript' })
    Server('review_typescript', { 'typescript' }, nil, 60)
    local paths = {
      Source('a.md'), Source('b.md'), Source('c.md'), Source('main.ts'),
    }
    local ready = require('vv-mcp.lsp.bootstrap').prepare(paths, 500)
    assert(ready == 2, '跨语言共享配置不能阻挡 TypeScript，且不能只等最快的客户端：' .. ready)
    assert(#Attempts.review_typescript >= 1, '必须实际触发 TypeScript LSP')
  end)
end

T['同一客户端已服务 JavaScript 时仍为 TypeScript 加载代表文件'] = function()
  fixture()
  child.lua_func(function()
    Server('review_script', { 'javascript', 'typescript' })
    local js = Source('doc-script.js')
    local ts = Source('source.ts')
    assert(require('vv-mcp.lsp.bootstrap').prepare({ js }, 500) == 1)
    assert(require('vv-mcp.lsp.bootstrap').prepare({ js, ts }, 500) == 1)
    assert(vim.fn.bufloaded(ts) == 1, 'JS 客户端就绪不能代替加载 TS 项目入口')
  end)
end

T['无扩展名脚本通过 shebang 启动对应客户端'] = function()
  fixture()
  child.lua_func(function()
    Server('review_python', { 'python' })
    local path = Source('script', { '#!/usr/bin/env python3', 'print(1)' })
    assert(require('vv-mcp.lsp.bootstrap').prepare({ path }, 500) == 1, 'shebang 应识别 Python')
    assert(#Attempts.review_python == 1)
  end)
end

T['多个配置共享等待预算且未初始化不算成功'] = function()
  fixture()
  child.lua_func(function()
    Server('review_lua', { 'lua' }, nil, 2000)
    Server('review_python', { 'python' }, nil, 2000)
    local paths = {}
    for i = 1, 4 do
      paths[#paths + 1] = Source(i .. '.lua')
      paths[#paths + 1] = Source(i .. '.py')
    end
    local start = vim.uv.hrtime()
    assert(require('vv-mcp.lsp.bootstrap').prepare(paths, 150) == 0, '不能把未初始化客户端当作成功')
    local elapsed = (vim.uv.hrtime() - start) / 1e6
    assert(elapsed < 400, '不能为每个候选或配置重新计时：' .. elapsed)
    assert(#Attempts.review_lua <= 3 and #Attempts.review_python <= 3)
  end)
end

T['不匹配候选也分片出让且超时后停止剩余扫描'] = function()
  fixture()
  child.lua_func(function()
    Server('review_lua', { 'lua' })
    local scanned, ticked = 0, false
    vim.filetype.add({ extension = { scan = function()
      scanned = scanned + 1
      local deadline = vim.uv.hrtime() + 2000000
      while vim.uv.hrtime() < deadline do end
      return 'text'
    end } })
    local paths = {}
    for i = 1, 100 do paths[i] = Source(i .. '.scan') end
    vim.defer_fn(function() ticked = true end, 5)
    assert(require('vv-mcp.lsp.bootstrap').prepare(paths, 40) == 0)
    assert(ticked, '扫描期间必须让定时回调执行')
    assert(scanned < #paths, '超时应停止剩余候选')
    local stopped = scanned
    vim.wait(60, function() return false end, 5)
    assert(scanned == stopped, '返回后不能继续扫描或加载文件')
  end)
end

return T
