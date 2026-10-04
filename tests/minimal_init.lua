-- 在替换 LSP 边界前加载 Neovim 的惰性诊断模块，避免替身被当成内部客户端
local _ = vim.lsp.diagnostic
