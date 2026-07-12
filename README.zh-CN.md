# vv-mcp.nvim

[English](./README.md) | [中文](./README.zh-CN.md)

通过 Model Context Protocol (MCP) 向 AI 代理暴露 Neovim 的 LSP 能力与实时编辑状态

> [!TIP]
> **在使用 VSCode？** 请看 [vsc-lsp-mcp](https://github.com/beixiyo/vsc-lsp-mcp) 获取同类 LSP 工作流

![LSP MCP demo](https://raw.githubusercontent.com/beixiyo/vsc-lsp-mcp/main/docAssets/demo.webp)

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

开发 vv-mcp 本身时可覆盖服务端路径：

可在仓库根目录构建调试版二进制：

```bash
cargo build
```

会在 `./target/debug/vv-mcp` 生成服务端二进制

```lua
{
  'beixiyo/vv-mcp.nvim',
  lazy = false,
  dependencies = { 'beixiyo/vv-utils.nvim' },
  opts = {
    server = {
      path = '/absolute/path/to/vv-mcp',
    },
  },
}
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

对于能够执行命令的编辑器或 Agent Hook，无需 MCP 客户端即可自动应用可用的 LSP 修复：

```bash
vv-mcp fix /absolute/path/to/file.ts
```

传入 `--line <行号>` 时仅应用该 1-based 行关联的 Quick Fix。省略时，命令会按文件路径选择实例、同步外部磁盘改动、应用可编辑的 `source.fixAll` 或 Quick Fix 并保存。没有匹配实例、LSP 或修复项时正常退出；Neovim 中存在未保存修改或 WorkspaceEdit 不安全时会拒绝执行

官方文档: [Codex](https://developers.openai.com/codex/mcp/), [Claude Code](https://docs.anthropic.com/en/docs/claude-code/mcp), [Cursor](https://docs.cursor.com/context/model-context-protocol), [Gemini CLI](https://geminicli.com/docs/tools/mcp-server/), [OpenCode](https://opencode.ai/docs/mcp-servers/)

## MCP 工具

| 工具 | 说明 |
|------|------|
| `health` | 查看服务端状态、实例注册表路径、输出格式与结果数量限制 |
| `list_instances` | 列出运行中的 Neovim 项目与已挂载 LSP |
| `resolve_instance` | 通过 `instanceId` 或绝对路径解析实例 |
| `lsp` | 执行带筛选的 LSP 操作 |
| `editor` | 读取实时编辑上下文、缓冲区、选区与未保存文本 |
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
| `read_buffer` | 单个已加载缓冲区实时文本，支持未保存改动与行范围 |
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
