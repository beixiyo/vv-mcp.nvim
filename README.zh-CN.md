<div align="center">

# vv-mcp.nvim

<a href="./README.md">English</a> | 中文

<img src="https://raw.githubusercontent.com/beixiyo/vsc-lsp-mcp/main/docAssets/demo.webp" alt="LSP MCP 演示" width="900" />

想要我的 Neovim 配置？查看 <a href="https://github.com/beixiyo/dotfiles">dotfiles</a>

<img src="https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white" alt="Neovim 0.10+" />
<img src="https://img.shields.io/badge/Lua-2C2D72?logo=lua&logoColor=white" alt="Lua" />
<a href="https://github.com/beixiyo/vv-mcp.nvim/actions"><img src="https://img.shields.io/github/actions/workflow/status/beixiyo/vv-mcp.nvim/ci.yml?label=CI" alt="CI" /></a>

</div>

通过 Model Context Protocol (MCP) 向 AI 代理暴露 Neovim 的 LSP 能力与实时编辑状态

> [!TIP]
> **在使用 VSCode？** 请看 [vsc-lsp-mcp](https://github.com/beixiyo/vsc-lsp-mcp) 获取同类 LSP 工作流

## 依赖

- [vv-utils.nvim](https://github.com/beixiyo/vv-utils.nvim) 0.4.0 或更高版本 — Neovim 客户端必须依赖
- [curl](https://github.com/curl/curl)、[wget](https://github.com/mirror/wget) 或 [PowerShell](https://github.com/PowerShell/PowerShell) 中任意一个 — 安装或更新托管的预编译 MCP 服务端时需要
- 当前语言已有运行中的 Neovim LSP 客户端 — 有实例时复用；没有时为目标项目启动受管 headless Neovim

## 为什么需要 vv-mcp.nvim

文本检索只能匹配字面内容，难以稳定回答语义类问题：

- 这个符号最终解析到了哪个声明？
- 哪些引用是真正语义引用而非文本匹配？
- 谁在调用这个函数，它调用了哪些内容？
- 当前激活的 LSP 提供了哪些类型、签名、诊断或修复？
- 未保存缓冲区在落盘前 Neovim 内部有哪些内容？

vv-mcp.nvim 让 AI 代理可以访问 Neovim 内已运行的 LSP 客户端与实时缓冲区：

- **语义导航**：定义、引用、实现、符号、悬浮、签名帮助、调用关系
- **诊断与修复**：过滤后的诊断、可安全应用的修复、文档级修复
- **安全重命名**：带预览的符号/文件/目录重命名，包含过期编辑保护
- **实时编辑状态**：当前上下文、已加载缓冲区、未保存文本与可视化选区
- **多实例路由**：请求可精确落在正确的 Neovim 实例，避免误配
- **紧凑返回**：对 LSP 结果进行过滤、去重、分组与限量输出

## 安装

使用 [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
return {
  'beixiyo/vv-mcp.nvim',
  lazy = false,
  dependencies = { 'beixiyo/vv-utils.nvim' },
  opts = {},
}
```

插件应在 Neovim 启动时加载，以便当前实例及时注册

## 配置

多数项目直接用默认 `opts = {}` 即可

dependency_markers 的 marker 用于过滤引用与调用链排序，默认覆盖常见 Node.js、Rust、Go、Java、Python、Mason 与 vendored 目录

若项目使用了自定义依赖目录，可重写 marker：

```lua
{
  'beixiyo/vv-mcp.nvim',
  lazy = false,
  dependencies = { 'beixiyo/vv-utils.nvim' },
  opts = {
    lsp = {
      dependency_markers = {
        '/node_modules/',
        '/vendor/',
        '/third_party/',
      },
    },
  },
}
```

marker 使用的是标准化路径片段，不是 glob 或 Lua pattern

开发 vv-mcp 时，可构建并安装到默认的 `~/.local/bin/vv-mcp`：

```bash
./scripts/build-dev
```

服务端默认输出为紧凑 JSON（最多 200 条）。服务端默认安装在 `~/.local/bin/vv-mcp`，可通过参数配置 stdio：

```json
{
  "command": "vv-mcp",
  "args": ["--output-format", "markdown", "--max-results", "100"]
}
```

或环境变量：

```text
VV_MCP_OUTPUT_FORMAT=markdown
VV_MCP_MAX_RESULTS=100
```

受管 headless 实例默认空闲 5 分钟后退出。同项目的真实 Neovim 注册后，受管实例会在 15 秒交接期后优雅退出。以下正整数毫秒环境变量可覆盖默认值：`VV_MCP_MANAGED_IDLE_TIMEOUT_MS`、`VV_MCP_MANAGED_HANDOFF_DELAY_MS`、`VV_MCP_MANAGED_WATCH_INTERVAL_MS`、`VV_MCP_MANAGED_READY_TIMEOUT_MS`

用 CLI 验证交接时，在 `lsp` 命令追加 `--keep-alive-ms 30000`。LSP 结果打印后进程管理器仍会保活，因此受管实例能观察到真实 Neovim 的注册

可用格式：

- `json`：紧凑机器可读输出
- `markdown`：面向模型的精简路径导向输出

位置使用 1-based 的 `line:character-line:character` 字符串，截断返回会同时给出展示数量和过滤数量

## MCP 客户端设置

服务端路径为：

```text
~/.local/bin/vv-mcp
```

自定义 `server.install_dir` 或 `server.path` 时使用 `:VVMcpInfo` 查看实际路径：

```vim
:VVMcpInfo
```

或：

```vim
:lua print(require('vv-mcp').server_path())
```

**Codex**

```bash
codex mcp add lsp-mcp -- vv-mcp
```

或写入 `~/.codex/config.toml`：

```toml
[mcp_servers.lsp-mcp]
command = "vv-mcp"
```

**Claude Code**

```bash
claude mcp add --scope user lsp-mcp -- vv-mcp
```

**Cursor** — `~/.cursor/mcp.json`

```json
{
  "mcpServers": {
    "lsp-mcp": {
      "command": "vv-mcp"
    }
  }
}
```

**OpenCode** — `~/.config/opencode/opencode.jsonc`

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "lsp-mcp": {
      "type": "local",
      "command": ["vv-mcp"],
      "enabled": true
    }
  }
}
```

修改 MCP 配置后重启客户端。请保持 Neovim 运行，以便保持项目实例可达

官方文档: [Codex](https://developers.openai.com/codex/mcp/) | [Claude Code](https://docs.anthropic.com/en/docs/claude-code/mcp) | [Cursor](https://docs.cursor.com/context/model-context-protocol) | [OpenCode](https://opencode.ai/docs/mcp-servers/)

## 命令行

同一个二进制既是 MCP 服务端，也是命令行工具。**不带子命令时进入 MCP 模式**(客户端就是这样启动它的)，带子命令时执行一次请求后退出。适合无法接入 MCP 的编辑器 Hook 与脚本

```bash
vv-mcp fix src/main.ts                # 应用并保存安全的 LSP 修复
vv-mcp fix src --all                  # 遵守 ignore 规则，串行修复整个目录
vv-mcp lsp --operation hover --uri src/main.ts --line 42 --character 17
vv-mcp editor --operation read_buffer --uri src/main.ts --start-line 1 --end-line 40
```

三个子命令:

| 子命令 | 说明 |
|--------|------|
| `fix` | 自动修复文件或目录并保存，输出 JSON，专为 Hook 设计 |
| `lsp` | 执行任意一个 LSP 操作，与 MCP `lsp` 工具共用同一份参数定义 |
| `editor` | 读取实时编辑器状态，全部只读 |

`vv-mcp <子命令> --help` 会列出全部操作与参数。几个通用约定:

- 路径按当前目录解析，相对路径可用
- 实例按路径自动路由；工作区重叠或操作不带路径时用 `--instance-id`(见 `vv-mcp --list-instances`)
- 会写盘的操作(`fix_document`、`code_action_apply`、`rename_apply`)必须显式传入 `--yes`
- 输出默认 markdown(给人看)，`--output-format json` 可切换；`vv-mcp fix` 始终输出 JSON，Hook 脚本无需调整
- 结果中带 error 时以退出码 1 结束

## MCP 工具

| 工具 | 说明 |
|------|------|
| `health` | 查看服务端状态、实例注册表路径、输出格式与结果数量限制 |
| `list_instances` | 列出运行中的 Neovim 项目与已挂载 LSP |
| `resolve_instance` | 通过 `instanceId` 或绝对路径解析实例 |
| `lsp` | 执行带筛选的 LSP 操作 |
| `editor` | 读取实时编辑上下文、缓冲区、选区与未保存文本；`read_buffer` 无实时缓冲区时回退到已保存的磁盘文本 |
| `workspace` | 预览并应用 LSP 感知的文件/目录重命名 |

**LSP 操作分类**

| 类别 | 操作 |
|----------|------------|
| 导航 | `definition`, `declaration`, `type_definition`, `implementation`, `references`, `document_highlight` |
| 文档 | `hover`, `signature_help`, `document_links`, `inlay_hints` |
| 符号 | `document_symbols`, `workspace_symbols` |
| 诊断 | `diagnostics`, `workspace_diagnostics` |
| 调用关系 | `prepare_call_hierarchy`, `incoming_calls`, `outgoing_calls` |
| 代码修复 | `code_actions`, `code_action_preview`, `fix_document_preview`, `fix_document`, `code_action_apply` |
| 重命名 | `prepare_rename`, `rename_preview`, `rename_apply` |

## 常见流程

**在使用基于位置的操作前先找符号**

对单文件用 `document_symbols`，对项目用 `workspace_symbols`，再将返回的 1-based range start 复用到 `hover`、`references`、重命名或调用关系查询

**查看调用关系图**

```text
prepare_call_hierarchy
  → incoming_calls
  → incoming_calls（带返回 callId）
```

使用 `outgoing_calls` 查看函数会调用哪些实现；当你更关注项目代码时，可传 `includeExternal=false`

**应用单个 Code Action**

```text
code_actions
  → code_action_preview
  → code_action_apply
```

预览会返回一次性 `actionId`，应用时会校验目标版本并写入改动、保存相关缓冲区

**修正文档问题**

```text
fix_document_preview
  → code_action_apply
```

文档修复优先 `source.fixAll`，退化为非重叠诊断快速修复

**重命名符号**

```text
prepare_rename
  → rename_preview
  → rename_apply
```

预览返回一次性 `renameId`，并在真正修改前列出受影响文件

**重命名文件/目录**

使用 `workspace` 工具：

```text
rename_resource_preview
  → rename_resource_apply
```

该流程会收集 `workspace/willRenameFiles` 编辑，更新 import/export，移动资源，刷新加载中的缓冲区名字，并发送 `workspace/didRenameFiles`

来源路径与目标路径都必须位于同一工作区根下。预览前请先保存来源路径下已修改缓冲区

## 实时编辑上下文

只读 `editor` 工具返回可能与落盘文件不同的状态：

| 操作 | 返回 |
|-----------|--------|
| `current_context` | 当前文件、光标、模式、工作目录、窗口、Tab 与 LSP 客户端 |
| `list_buffers` | 可编辑的已加载文件缓冲区，设置 `includeSpecial=true` 可包含插件/终端缓冲区 |
| `read_buffer` | 单个已加载缓冲区实时文本，支持未保存改动与行范围；无实时缓冲区时返回 `source: disk` 的已保存磁盘文本 |
| `get_selection` | 当前字符级/行级/块级选区文本及 1-based range |

多实例共存时，当前状态相关操作请显式传 `instanceId`

## 大结果过滤

过滤发生在结果限制前，避免无关内容掩盖有效条目：

| 操作 | 过滤项 |
|-----------|---------|
| `document_symbols` | `query`, `symbolKinds` |
| `references` | `includeDeclaration`, `includeExternal`, `pathPattern` |
| `diagnostics`, `workspace_diagnostics` | `severities`, `sources`, `codes` |
| `incoming_calls`, `outgoing_calls` | `includeExternal` |
| `inlay_hints` | `startLine`, `endLine` |

调用关系优先展示 workspace 节点，再是依赖，最后是外部文件；函数与构造器先于方法与其他符号种类显示

## 命令

| 命令 | 用途 |
|---------|---------|
| `:VVMcpInfo` | 显示当前实例与 MCP 服务端路径 |
| `:VVMcpRefresh` | 刷新当前实例记录 |
| `:VVMcpInstall` | 安装托管 MCP 服务端 |
| `:VVMcpUpdate` | 更新托管 MCP 服务端 |
| `:VVMcpUninstall` | 卸载托管 MCP 服务端 |

## 安全边界

- MCP 服务端仅连接本地 Neovim socket 或 loopback TCP
- 编辑器相关操作均为只读
- 预览类操作不直接修改缓冲区或文件
- 应用类操作会拒绝过期、重复、重叠、命令型或不被支持的编辑
- 资源重命名限制在同一工作区根下
- Neovim 退出或服务端检测到陈旧状态时会清理实例记录

## 架构

每个 Neovim 进程会在本地实例注册表记录 RPC 地址、项目根、工作目录与已挂载 LSP 客户端

Rust MCP 服务端是 Broker：接收 MCP 请求，选定匹配 Neovim 实例，经由 MessagePack RPC 转发操作，再返回紧凑结果

```text
AI agent
  │ stdio MCP
  ▼
vv-mcp Rust server
  │ local registry + project-root routing
  ▼
matching Neovim process
  │ MessagePack RPC
  ▼
Lua handlers → attached LSP clients / live buffers
```

实例路由顺序为：

1. 如果提供 `instanceId` 则优先使用它
2. 否则选取其项目根与目标路径前缀匹配最长的实例
3. 若存在同长度歧义则判定为 ambiguous 并拒绝猜测
4. 忽略并清理陈旧实例记录

这使得嵌套工作区能选中更具体的 Neovim 实例，同时对重叠实例保持明确和安全

## 许可证

[MIT](./LICENSE)

## 开发测试

Linux/macOS 准备 Neovim 0.12+、Git 和 POSIX 基础工具后，将本仓与包含 `dev/test/` 的 vv-utils.nvim 检出为兄弟目录，直接运行入口。源码不在兄弟目录时才需设置 `VV_UTILS`；测试不读取个人配置，不依赖 parser、Rust 工具链或真实 MCP 二进制

```sh
sh tests/run.sh
# 非默认源码位置或 Neovim 可执行文件可覆盖
VV_UTILS=/path/to/vv-utils.nvim NVIM_BIN=/path/to/nvim sh tests/run.sh
sh tests/run.sh '过滤词'
```

要求 Neovim 0.12+、POSIX shell 和[共享 pinned mini.test 入口](../vv-utils.nvim/dev/test/README.md)
`VV_UTILS` 默认兄弟仓库 `vv-utils.nvim`，`NVIM_BIN` 默认 `nvim`。可选过滤词按文件路径或中文用例名
做**字面子串**匹配，不是 pattern；没有匹配视为失败。离线运行须先准备固定版本 mini.test 缓存，
可用 `VV_TEST_DEPS_CACHE=/path/to/nvim-test-deps` 显式指定；本套件不安装业务依赖

每个具名 case 启动全新子 Neovim，不读取个人配置；cwd、HOME、XDG 与临时文件都位于独立 `/tmp`
父 hook 在断言失败时仍停止子进程并清理 fixture；scheduled 回调异常单独收集后断言
headless 状态验证不能替代真实终端的视觉和鼠标验证

CI 的 stable / nightly 与 release 的 Lua 验证均调用 `sh tests/run.sh`，由共享入口递归收集、执行具名集合并传播失败退出码，不再用 `nvim -l tests/test_*.lua` 直接加载集合。Ubuntu 24.04 stable 使用 Neovim v0.12.0 并作为必过门；nightly 保留实验性非阻断策略。Lua CI 设置 10 分钟外层超时，发布 verify（含 Rust）设置 45 分钟超时，避免同步 RPC 卡住任务。Rust 检查和二进制构建仍由原有独立流程执行

共享 mini.test 固定版本由 vv-utils 管理，在线首次运行会下载到测试缓存；离线执行须提前准备该缓存。迁移发布时先提交并发布 vv-utils 的 `dev/test/`，再发布本仓新的测试集合及 helpers；仅修改本仓 workflow、但远端 vv-utils 缺少共享入口时，CI 会明确失败

发布资产、下载器和 LSP 客户端都使用本地替身，不下载真实二进制，不发起远程网络请求
二进制场景用本地假 `curl` 与模拟发布字节；取消场景使用本地 shell 进程，并保留独立的失败清理用例，
父 hook 也会终止遗留 fixture PID。需要 Neovim RPC/socket 支持、POSIX shell 及可写、可执行的 `/tmp`；fixture 不触及开发仓库 Git。Docker 的 tmpfs 默认可能带 `noexec`，请显式使用 `--tmpfs /tmp:rw,nosuid,nodev,exec,size=512m`，否则本地假下载器即使有执行位也无法启动
