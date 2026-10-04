# Changelog

## 0.3.4 - 2026-08-27

- MCP 会话结束、服务等待失败或收到 SIGTERM / SIGINT 时回收受管 Neovim，避免遗留 LSP 子进程；信号退出码为 143
- 受管 Neovim 默认空闲回收时间从 15 分钟缩短为 5 分钟
- 修复开发构建被误判为旧版本并触发不存在的 Release 下载

## 0.3.3 - 2026-07-27

- 最低依赖升级为 `vv-utils 0.4.0`，补齐 LSP 配置与可执行文件预检
- 实例路由仅注册启动 CWD 对应的 Git 或语言项目根，不再纳入其他 LSP 的 `workspace_folders`

## 0.3.2 - 2026-07-27

- 受管实例仅在 LSP 仍初始化时重试，`no_lsp` 等终态错误不再等待就绪超时
- `fix` 遇到缺少配置、可执行文件或启动失败时无修改跳过，写后钩子可快速结束

## 0.3.1 - 2026-07-26

- `read_buffer` 无实时 buffer 或运行中 Neovim 时回退读取磁盘文本并标注 `source: disk`，保留显式实例路由错误，支持百分号编码的本地 `file://` URI
- LSP 请求无匹配实例时按 Git 优先、语言 manifest 回退的项目根启动受管 headless Neovim，空闲 15 分钟后回收
- 同项目真实 Neovim 注册后，受管实例在可配置交接期后退出；CLI 可用 `lsp --keep-alive-ms` 诊断交接
- 注册失败时立即回收，成功后等待 LSP 就绪，普通 CLI 请求退出时清理托管子进程与 socket

## 0.3.0

- 新增 `vv-mcp fix <path> [--line <number>]` 安全修复并保存文件，`fix <directory> --all` 通过固定实例顺序修复目录
- 新增 `vv-mcp lsp --operation <name>` 暴露全部 LSP 操作，`editor --operation <name>` 只读查询实时编辑器状态并遵守 `--max-results`
- 子命令默认 Markdown，MCP 默认 JSON；`--output-format` 或 `VV_MCP_OUTPUT_FORMAT` 优先，`fix` 保持 JSON
- 共享 CLI 参数可出现在任意位置且均生效，完整用法见 [命令行](README.zh-CN.md#命令行)
- 写盘操作 `fix_document`、`code_action_apply`、`rename_apply` 必须显式传 `--yes`
- 终端无参数运行显示帮助，管道 stdin 仍提供 stdio MCP 服务
- LSP 挂载改变项目根时保持实例身份稳定

## 0.2.0

- 新增多实例路由、紧凑过滤的 LSP 输出及实时编辑上下文、诊断、调用关系、inlay hints、文档链接与高亮
- 新增预览后应用的符号重命名、Code Actions、文档修复及 LSP 感知的文件 / 目录重命名
- 拒绝陈旧、复用、重叠、仅命令及不支持的 workspace 编辑
- 新增预编译服务端自动安装、SHA-256 验证及 CI / 标签驱动的跨平台 GitHub Releases
- 支持 curl、wget、PowerShell 7 和 Windows PowerShell，缺少依赖时提供明确提示
- 补充运行中 `vv-mcp.exe` 的托管二进制更新说明
