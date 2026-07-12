# Changelog

## Unreleased

- Add `vv-mcp fix <path> [--line <number>]` for command-based hooks that apply and save safe LSP fixes
- Add `vv-mcp fix <directory> --all` for sequential repository fixes through one pinned Neovim instance
- Keep instance identity stable when LSP attachment changes the discovered project roots

## 0.2.0

- Add multi-instance Neovim routing with compact filtered LSP output
- Add live editor context, diagnostics, call hierarchy, inlay hints, document links, and highlights
- Add preview-gated symbol rename, Code Actions, document fixes, and LSP-aware file or directory rename
- Reject stale, reused, overlapping, command-only, and unsupported workspace edits
- Add prebuilt server auto-installation with SHA-256 verification
- Add CI and tag-driven cross-platform GitHub Releases
- Support `curl`, `wget`, PowerShell 7, and Windows PowerShell with actionable missing-dependency errors
- Explain how to update a managed Windows binary when `vv-mcp.exe` is still running
