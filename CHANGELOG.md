# 更新日志

## 0.3.0

- 添加 `vv-mcp fix <path> [--line <number>]` 用于基于命令的钩子，应用并保存安全的 LSP 修复
- 添加 `vv-mcp fix <directory> --all` 用于通过一个固定的 Neovim 实例顺序修复仓库
- 添加 `vv-mcp lsp --operation <name>` 在命令行暴露所有 LSP 操作；MCP schema、wire payload 与 CLI 标志从单一参数定义生成
- 添加 `vv-mcp editor --operation <name>` 用于只读实时编辑器状态，为 `editor` 工具提供紧凑 JSON 与 Markdown 输出，遵守 `--max-results`
- 子命令默认输出 Markdown，MCP 服务端默认 JSON；显式 `--output-format` 或 `VV_MCP_OUTPUT_FORMAT` 仍然优先，`vv-mcp fix` 保持 JSON 约定
- 接受 `--registry`、`--output-format`、`--max-results`、`--instance-id` 与 `--timeout-ms` 出现在命令行任何位置；每个子命令都路由到实例并发出 RPC，因此它们都真实生效而非被静默忽略
- 写盘的命令行操作需要 `--yes` 参数（`fix_document`、`code_action_apply`、`rename_apply`）
- 在终端中无参数运行时打印帮助，而不是静默等待；stdin 为管道时（MCP 客户端的启动方式）仍照常提供 stdio MCP 服务
- 当 LSP 挂载改变发现的项目根时保持实例身份稳定

## 0.2.0

- 添加多实例 Neovim 路由与紧凑过滤 LSP 输出
- 添加实时编辑上下文、诊断、调用关系、inlay hints、文档链接与高亮
- 添加预览网关的符号重命名、Code Actions、文档修复与 LSP 感知的文件或目录重命名
- 拒绝陈旧的、复用的、重叠的、仅命令的与不支持的 workspace 编辑
- 添加预编译服务端自动安装与 SHA-256 验证
- 添加 CI 与标签驱动的跨平台 GitHub Releases
- 支持 `curl`、`wget`、PowerShell 7 与 Windows PowerShell，并提供可操作的缺失依赖错误提示
- 说明当 `vv-mcp.exe` 仍在运行时如何更新托管 Windows 二进制文件
