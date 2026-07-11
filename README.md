# vv-mcp.nvim

Expose active Neovim LSP clients to AI agents through MCP

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

## Output configuration

LSP results are flattened before they reach the AI: URI wrappers and redundant LSP ranges are removed, locations are grouped by file path, duplicate locations are removed, and ranges use compact 1-based `line:character-line:character` strings

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

- `json` (default): compact machine-readable locations grouped by path
- `markdown`: concise path-oriented bullets for direct model consumption

`--max-results` defaults to `200` and must be greater than zero. The limit applies globally to each LSP response after duplicate locations are removed. A truncated response explicitly reports how many results were shown and how many were available

Example Markdown response:

```markdown
## References
Clients: `tsgo`
- `/project/src/a.ts`: 10:3-10:12, 25:5-25:14
(Showing 100 of 340 results)
```

## Safe rename

Rename is a three-step transaction:

1. `prepare_rename` confirms the symbol and range
2. `rename_preview` returns a single-use `renameId` and a capped edit summary without changing files
3. `rename_apply` rejects expired or stale previews, applies every edit, and saves all target buffers to disk

When several LSP clients are attached to one buffer, vv-mcp waits for and selects a client that supports the requested method. Formatting and utility clients therefore do not block a rename-capable language server
