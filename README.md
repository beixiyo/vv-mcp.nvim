# vv-mcp.nvim

[English](./README.md) | [中文](./README.zh-CN.md)

Expose Neovim LSP intelligence and live editor state to AI agents through the Model Context Protocol (MCP)

> [!TIP]
> **Using VSCode?** See [vsc-lsp-mcp](https://github.com/beixiyo/vsc-lsp-mcp) for the same LSP workflows

![LSP MCP demo](https://raw.githubusercontent.com/beixiyo/vsc-lsp-mcp/main/docAssets/demo.webp)

## Why vv-mcp.nvim?

Text search can find matching words, but it cannot reliably answer semantic questions:

- Which declaration does this symbol resolve to?
- Which references are real usages rather than text matches?
- Who calls this function, and what does it call?
- What types, signatures, diagnostics, or fixes does the active LSP provide?
- What does Neovim currently contain before an unsaved buffer reaches disk?

vv-mcp.nvim gives AI agents access to the LSP clients and live buffers already running inside Neovim

- **Semantic navigation** — definitions, references, implementations, symbols, hover, signatures, and call hierarchy
- **Diagnostics and fixes** — filtered diagnostics, safe Code Actions, and document-wide fixes
- **Safe rename** — preview-gated symbol, file, and directory rename with stale-edit protection
- **Live editor state** — current context, loaded buffers, unsaved text, and Visual selections
- **Multiple Neovim instances** — route requests to the correct project instead of guessing
- **Compact output** — filter, deduplicate, group, and limit LSP results before returning them to the model

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
return {
  'beixiyo/vv-mcp.nvim',
  lazy = false,
  dependencies = { 'beixiyo/vv-utils.nvim' },
  opts = {},
}
```

The plugin must load during Neovim startup so the current instance can be registered immediately

## Configuration

The default `opts = {}` is sufficient for most projects

Dependency markers classify paths when filtering references and sorting call hierarchy nodes. The defaults cover common Node.js, Rust, Go, Java, Python, Mason, and vendored dependency directories

Override the complete marker list when a project uses custom dependency paths:

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

Markers are normalized path substrings, not glob or Lua patterns

Use a custom server binary when developing vv-mcp itself:

It builds a debug binary at `./target/debug/vv-mcp`:

```bash
cargo build
```

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

The default server output is compact JSON with at most 200 results. The server is installed at `~/.local/bin/vv-mcp`. Configure the stdio command through arguments:

```json
{
  "command": "vv-mcp",
  "args": ["--output-format", "markdown", "--max-results", "100"]
}
```

or environment variables:

```text
VV_MCP_OUTPUT_FORMAT=markdown
VV_MCP_MAX_RESULTS=100
```

Available formats:

- `json` — compact machine-readable output
- `markdown` — concise path-oriented output for direct model consumption

Positions use 1-based `line:character-line:character` strings. Truncated responses report both the shown and filtered totals

## MCP client setup

The default server path is:

```text
~/.local/bin/vv-mcp
```

Use `:VVMcpInfo` when `server.install_dir` or `server.path` is customized:

```vim
:VVMcpInfo
```

or:

```vim
:lua print(require('vv-mcp').server_path())
```

**Codex**

```bash
codex mcp add lsp-mcp -- vv-mcp
```

or add it to `~/.codex/config.toml`:

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

Restart the MCP client after changing its configuration. Keep Neovim running so the project instance remains available

For editor and agent hooks that can run commands, apply available LSP fixes without an MCP client:

```bash
vv-mcp fix /absolute/path/to/file.ts
vv-mcp fix /absolute/path/to/project --all
```

Pass `--line <number>` to apply only Quick Fixes associated with one 1-based line. Without it, the command routes by file path, synchronizes external disk changes, applies editable `source.fixAll` or quick-fix actions, and saves the result. No matching instance, LSP, or fix is a successful no-op. Unsaved Neovim buffers and unsafe workspace edits are rejected

Pass `--all` with a directory to walk non-ignored files and fix them sequentially through one active Neovim instance. The instance is resolved once and pinned for the whole run; temporary buffers created for unopened files are removed after each request. Directory mode requires a running vv-mcp-enabled Neovim instance whose workspace contains the path

Official MCP setup documentation: [Codex](https://developers.openai.com/codex/mcp/), [Claude Code](https://docs.anthropic.com/en/docs/claude-code/mcp), [Cursor](https://docs.cursor.com/context/model-context-protocol), [Gemini CLI](https://geminicli.com/docs/tools/mcp-server/), [OpenCode](https://opencode.ai/docs/mcp-servers/)

## MCP tools

| Tool | Purpose |
|------|---------|
| `health` | Show server status, registry path, output format, and result limit |
| `list_instances` | List running Neovim projects and attached LSP clients |
| `resolve_instance` | Resolve an instance from an `instanceId` or absolute path |
| `lsp` | Execute a filtered LSP operation |
| `editor` | Read live Neovim context, buffers, selections, and unsaved text |
| `workspace` | Preview and apply LSP-aware file or directory renames |

**LSP operations**

| Category | Operations |
|----------|------------|
| Navigation | `definition`, `declaration`, `type_definition`, `implementation`, `references`, `document_highlight` |
| Documentation | `hover`, `signature_help`, `document_links`, `inlay_hints` |
| Symbols | `document_symbols`, `workspace_symbols` |
| Diagnostics | `diagnostics`, `workspace_diagnostics` |
| Call hierarchy | `prepare_call_hierarchy`, `incoming_calls`, `outgoing_calls` |
| Code Actions | `code_actions`, `code_action_preview`, `fix_document_preview`, `fix_document`, `code_action_apply` |
| Rename | `prepare_rename`, `rename_preview`, `rename_apply` |

## Common workflows

**Find a symbol before using position-based operations**

Use `document_symbols` for a known file or `workspace_symbols` for a project-wide name query. Reuse the returned 1-based range start in `hover`, `references`, rename, or call hierarchy requests

**Inspect a call graph**

```text
prepare_call_hierarchy
  → incoming_calls
  → incoming_calls with a returned callId
```

Use `outgoing_calls` to inspect what the selected function calls. Pass `includeExternal=false` when project code matters more than dependency or standard-library nodes

**Apply one Code Action**

```text
code_actions
  → code_action_preview
  → code_action_apply
```

The preview returns a single-use `actionId`. Applying it validates the target versions, writes the edits, and saves the affected buffers

**Fix a document**

```text
fix_document_preview
  → code_action_apply
```

Document fixes prefer LSP `source.fixAll` actions and fall back to non-overlapping diagnostic quick fixes

**Rename a symbol**

```text
prepare_rename
  → rename_preview
  → rename_apply
```

The preview returns a single-use `renameId` and reports every affected file before anything changes

**Rename a file or directory**

Use the separate `workspace` tool:

```text
rename_resource_preview
  → rename_resource_apply
```

The operation collects `workspace/willRenameFiles` edits, updates imports and exports, moves the resource, synchronizes loaded buffer names, and sends `workspace/didRenameFiles`

Both paths must remain inside one workspace root. Save modified buffers below the source path before previewing the rename

## Live editor context

The read-only `editor` tool exposes state that may differ from files on disk:

| Operation | Result |
|-----------|--------|
| `current_context` | Current file, cursor, mode, working directory, window, tab, and attached LSP clients |
| `list_buffers` | Editable loaded file buffers; pass `includeSpecial=true` to include plugin and terminal buffers |
| `read_buffer` | Live text from one loaded buffer, including unsaved changes and optional line ranges |
| `get_selection` | Current character, line, or block Visual selection with text and a 1-based range |

Use an explicit `instanceId` for current-state operations when several Neovim instances are running

## Filtering large results

Filters run before the result limit, so relevant items are not hidden by unrelated entries:

| Operation | Filters |
|-----------|---------|
| `document_symbols` | `query`, `symbolKinds` |
| `references` | `includeDeclaration`, `includeExternal`, `pathPattern` |
| `diagnostics`, `workspace_diagnostics` | `severities`, `sources`, `codes` |
| `incoming_calls`, `outgoing_calls` | `includeExternal` |
| `inlay_hints` | `startLine`, `endLine` |

Call hierarchy results prioritize workspace nodes, then dependencies, then external files. Functions and constructors are shown before methods and other symbol kinds

## Commands

| Command | Purpose |
|---------|---------|
| `:VVMcpInfo` | Show the current instance and MCP server path |
| `:VVMcpRefresh` | Refresh the current instance record |
| `:VVMcpInstall` | Install the managed MCP server |
| `:VVMcpUpdate` | Update the managed MCP server |
| `:VVMcpUninstall` | Remove the managed MCP server |

## Safety boundaries

- The MCP server only connects to local Neovim sockets or loopback TCP addresses
- Editor operations are read-only
- Preview operations never modify buffers or files
- Apply operations reject stale, expired, reused, overlapping, command-only, and unsupported edits
- Resource renames are restricted to one workspace root
- Instance records are removed when Neovim exits or when the server detects stale state

## Architecture

Each Neovim process registers its RPC address, project roots, working directory, and attached LSP clients in a local instance registry

The Rust MCP server acts as a Broker: it receives one MCP request, selects the matching Neovim process, forwards the operation through MessagePack RPC, and returns a compact result

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

Instance routing follows this order:

1. Use an explicit `instanceId` when provided
2. Otherwise choose the instance whose project root is the longest prefix of the target path
3. Reject equally specific matches as ambiguous instead of guessing
4. Ignore and clean stale instance records

This allows nested workspaces to select the most specific Neovim process while keeping overlapping instances explicit and safe

## License

[MIT](./LICENSE)
