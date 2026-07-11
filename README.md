# vv-mcp.nvim

Expose Neovim LSP intelligence and live editor context to AI agents through the Model Context Protocol (MCP)

> **Using VS Code?** See [vsc-lsp-mcp](https://github.com/beixiyo/vsc-lsp-mcp), the sibling implementation with a shared multi-window Broker, filtered LSP operations, transactional rename, and safe Code Actions

## Overview

AI coding agents can search files, but text search alone cannot reliably answer semantic questions such as:

- Which declaration does this symbol resolve to?
- Which calls are real function calls rather than imports or text matches?
- What signature, parameter, type, or documentation does the active language server provide?
- Which diagnostics and quick fixes are currently available?
- What does Neovim contain before an unsaved buffer reaches disk?
- Which Neovim process owns a file when several projects are open?

vv-mcp.nvim connects AI agents to the same LSP clients and live buffers already running inside Neovim. A small Lua plugin registers each Neovim process, while the `vv-mcp` Rust server discovers the correct instance, executes requests through Neovim RPC, and compresses the results before returning them to the model

![LSP MCP demo](https://raw.githubusercontent.com/beixiyo/vsc-lsp-mcp/main/docAssets/demo.webp)

## Why vv-mcp.nvim?

- **Semantic navigation instead of text guessing** — definitions, references, symbols, hover, signatures, diagnostics, and call hierarchy come from the attached LSP clients
- **Live editor state** — agents can read unsaved buffers, the current cursor context, visible files, and Visual selections without pretending disk content is current
- **Multiple Neovim instances** — requests route by exact `instanceId` or the longest matching project root
- **Token-efficient output** — raw LSP wrappers are flattened, duplicate locations are removed, paths are grouped, and large lists are capped after filtering
- **Safe writes** — rename and Code Actions require a preview before apply; stale, expired, reused, overlapping, command-only, and unsupported resource edits are rejected
- **Multi-LSP aware** — formatting and utility clients do not block semantic clients such as `tsgo`, `rust_analyzer`, `gopls`, or `jdtls`

## Features

- 24 LSP operations across navigation, documentation, diagnostics, symbols, call hierarchy, rename, and Code Actions
- Read-only live editor context through a separate `editor` tool
- Compact JSON and Markdown output with configurable `max-results`
- Case-insensitive symbol-name, diagnostic source/code, and path filters where applicable
- Workspace-first call hierarchy sorting so dependency methods do not consume the result budget
- 1-based input and output positions that can be reused directly between calls
- Local multi-instance registry with automatic stale-instance cleanup

## Architecture

### What is a Broker?

A Broker is an intermediary that receives a request, selects the process capable of handling it, forwards the request, and returns the response. It does not replace Neovim or the language server

In vv-mcp.nvim, the Rust `vv-mcp` process is both the public MCP server and the Broker:

- MCP clients only communicate with one stable stdio process
- the Broker reads the instance registry and selects the correct Neovim process
- the selected Neovim process executes the request against its own buffers and attached LSP clients
- the Broker compresses the result into JSON or Markdown before returning it to the AI

```text
AI agent
  │ stdio MCP
  ▼
vv-mcp Rust server
  │ instance registry + project-root routing
  ▼
matching Neovim process
  │ MessagePack RPC / exec_lua
  ▼
Lua handlers → attached LSP clients / live buffers
```

### How multi-instance routing works

Every Neovim process has an independent RPC socket and its own buffers, working directory, and LSP clients. The Lua plugin publishes the following metadata to the local registry:

```json
{
  "instanceId": "react-tool-aee4be3b:72852",
  "pid": 72852,
  "socket": "/tmp/nvim.72852.0",
  "cwd": "/code/react-tool",
  "roots": ["/code/react-tool", "/code/react-tool/packages/app"],
  "lspClients": ["tailwindcss", "tsgo"]
}
```

The registry is refreshed when Neovim starts and when focus, directory, or LSP attachment state changes. It is removed on `VimLeavePre`; stale records are also ignored and cleaned by the Rust server

For each request, the Broker resolves the instance in this order:

1. Use an explicit `instanceId` when provided
2. Otherwise select the instance whose project root is the longest path prefix of `uri`
3. Reject equally specific matches as ambiguous instead of guessing
4. Connect to the selected Neovim socket and execute the Lua LSP/editor handler through MessagePack RPC

For example, `/code/app/packages/ui/src/Button.tsx` prefers an instance rooted at `/code/app/packages/ui` over one rooted at `/code/app`. If two Neovim processes open the same root, call `list_instances` and pass the intended `instanceId`

## MCP tools

| Tool | Purpose |
|------|---------|
| `health` | Report registry path, output format, and result limit |
| `list_instances` | List running Neovim projects, roots, sockets, and attached LSP clients |
| `resolve_instance` | Resolve one instance explicitly by `instanceId` or absolute file path |
| `lsp` | Execute one filtered LSP operation through the matching Neovim instance |
| `editor` | Read live Neovim context, buffers, selections, and unsaved text |
| `workspace` | Preview and apply LSP-aware file or directory renames |

### LSP operations

| Category | Operations |
|----------|------------|
| Navigation | `definition`, `declaration`, `type_definition`, `implementation`, `references`, `document_highlight` |
| Documentation | `hover`, `signature_help`, `document_links`, `inlay_hints` |
| Symbols | `document_symbols`, `workspace_symbols` |
| Diagnostics | `diagnostics`, `workspace_diagnostics` |
| Call hierarchy | `prepare_call_hierarchy`, `incoming_calls`, `outgoing_calls` |
| Code Actions | `code_actions`, `code_action_preview`, `fix_document_preview`, `code_action_apply` |
| Rename | `prepare_rename`, `rename_preview`, `rename_apply` |

When a symbol position is uncertain, call `document_symbols` for a known file or `workspace_symbols` with a project query, then reuse the returned 1-based range start

## Installation

Build and install the Rust MCP server:

```bash
cargo install --path crates/vv-mcp
```

Load the Neovim plugin and call setup:

```lua
vim.pack.add({
  { src = 'https://github.com/beixiyo/vv-mcp.nvim' },
})

require('vv-mcp').setup()
```

Then configure the MCP client to launch the stdio server:

```json
{
  "mcpServers": {
    "vv-mcp": {
      "command": "vv-mcp"
    }
  }
}
```

Restart Neovim after installation so the instance registry contains the active editor process

## Neovim configuration

Paths containing a dependency marker are classified as dependencies when filtering references and sorting call hierarchy nodes. Override the defaults through `setup` when a project uses a custom dependency directory:

The defaults cover Node.js (`node_modules`, pnpm), Rust (Cargo and rustlib), Go module caches, Java Maven/Gradle caches, Python virtual environments, Mason packages, and vendored dependencies

```lua
require('vv-mcp').setup({
  lsp = {
    dependency_markers = {
      '/node_modules/',
      '/vendor/',
      '/third_party/',
    },
  },
})
```

`dependency_markers` uses normalized path substrings rather than glob or Lua patterns. Providing the option replaces the complete default list

Available commands:

- `:VVMcpInfo` — show the current instance and registry record
- `:VVMcpRefresh` — refresh the current instance immediately

## Live editor context

The read-only `editor` MCP tool exposes Neovim state that may differ from files on disk:

- `current_context` — current buffer, cursor, mode, working directory, window, tab, filetype, modified state, and attached LSP clients
- `list_buffers` — editable loaded file buffers with visibility and modified state; `includeSpecial=true` also returns plugin, terminal, help, and other special buffers
- `read_buffer` — live text from one loaded buffer, including unsaved changes; supports 1-based line ranges and defaults to 200 lines
- `get_selection` — current character, line, or block Visual selection with text and a 1-based range

Use `instanceId` for current-state operations when several Neovim instances are running. `read_buffer` can select an instance automatically from its absolute `uri`

## Filtering large results

Filters are applied before `max-results`, so relevant items are not hidden behind arbitrary truncation:

- `document_symbols` — `query`, `symbolKinds`
- `references` — `includeDeclaration`, `includeExternal`, `pathPattern`
- `diagnostics`, `workspace_diagnostics` — `severities`, `sources`, `codes`
- `incoming_calls`, `outgoing_calls` — `includeExternal`
- `inlay_hints` — `startLine`, `endLine`

Call hierarchy results are sorted by `workspace > dependency > external`, then by `Function/Constructor > Method > other`

## Safe rename and Code Actions

Rename is a three-step transaction:

1. `prepare_rename` confirms the symbol and range
2. `rename_preview` returns a single-use `renameId` and a capped edit summary without changing files
3. `rename_apply` rejects expired or stale previews, applies every edit, and saves all target buffers to disk

A specific Code Action follows the same safety model:

1. `code_actions` lists editable actions at an exact diagnostic or symbol position
2. `code_action_preview` returns the affected files and ranges without modifying them
3. `code_action_apply` validates and saves the single-use transaction

For an entire document, use `fix_document_preview -> code_action_apply`. It prefers LSP `source.fixAll` actions and falls back to non-overlapping diagnostic quick fixes. Command-only actions and file resource operations are not applied

## File and directory rename

The separate `workspace` tool provides an LSP-aware resource rename transaction:

1. `rename_resource_preview` validates `oldUri` and `newUri`, collects `workspace/willRenameFiles` import edits, and returns `resourceRenameId` without modifying files
2. `rename_resource_apply` revalidates the source, target, buffers, and edits; saves import updates; moves the file or directory; synchronizes loaded buffer names; and sends `workspace/didRenameFiles`

Both paths must remain inside one workspace root. Save modified buffers below the source path before preview. File resource edits returned inside `willRenameFiles` are rejected because they cannot be merged safely with the explicit move transaction

## Output configuration

LSP results are flattened before they reach the AI: URI wrappers and redundant ranges are removed, locations are grouped by file path, duplicate locations are removed, and positions use compact 1-based `line:character-line:character` strings

The default output is compact JSON with at most 200 results:

```json
{
  "clients": ["tsgo"],
  "locations": {
    "/project/src/a.ts": ["10:3-10:12", "25:5-25:14"]
  }
}
```

Configure the stdio server with command-line arguments:

```json
{
  "command": "vv-mcp",
  "args": ["--output-format", "markdown", "--max-results", "100"]
}
```

Or environment variables:

```text
VV_MCP_OUTPUT_FORMAT=markdown
VV_MCP_MAX_RESULTS=100
```

Available formats:

- `json` (default) — compact machine-readable locations grouped by path
- `markdown` — concise path-oriented bullets for direct model consumption

`--max-results` defaults to `200` and must be greater than zero. A truncated response explicitly reports how many filtered results were shown and how many were available

Example Markdown response:

```markdown
## References
Clients: `tsgo`
- `/project/src/a.ts`: 10:3-10:12, 25:5-25:14
(Showing 100 of 340 results)
```

## Security boundaries

- The MCP server connects only to local Neovim sockets or loopback TCP addresses
- Editor operations are read-only
- Preview operations never modify buffers or files
- Apply operations reject stale, expired, reused, overlapping, command-only, and unsupported resource edits
- Instance records are local runtime metadata and are removed when Neovim exits or becomes stale

## License

[MIT](./LICENSE)
