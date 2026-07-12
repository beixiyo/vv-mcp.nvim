vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:prepend(vim.fn.getcwd() .. '/../vv-utils.nvim')

-- 预加载 vim.lsp.diagnostic：它是惰性模块，首次访问会执行初始化并回查当前 LSP 客户端
-- 若等到测试替换掉 vim.lsp.get_clients / get_client_by_id 之后才触发加载，
-- Neovim 会把测试替身当成真实 client（Neovim nightly 的加载路径正是如此），进而索引到替身没有的内部字段
local _ = vim.lsp.diagnostic
