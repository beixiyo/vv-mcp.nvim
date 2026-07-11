use std::{path::PathBuf, time::Duration};

use anyhow::Result;
use rmcp::{
    ServerHandler,
    handler::server::wrapper::Parameters,
    model::{Implementation, ServerCapabilities, ServerInfo},
    schemars, tool, tool_handler, tool_router,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{
    instance::{Instance, InstanceList, Registry, resolve_instance},
    nvim::{NvimClient, NvimError},
    output::OutputConfig,
};

const LSP_REQUEST: &str = "return require('vv-mcp.lsp').request(...)";
const DEFAULT_LSP_TIMEOUT_MS: u32 = 3000;
const RPC_TIMEOUT_MARGIN_MS: u64 = 1000;

#[derive(Clone, Debug)]
pub struct VvMcpServer {
    registry: Registry,
    output: OutputConfig,
}

#[tool_router]
impl VvMcpServer {
    pub fn new(registry: Option<PathBuf>, output: OutputConfig) -> Result<Self> {
        Ok(Self {
            registry: Registry::new(registry)?,
            output,
        })
    }

    pub async fn instances(&self) -> Result<InstanceList> {
        self.registry.list().await
    }

    #[tool(description = "List running Neovim project instances available for LSP requests.")]
    async fn list_instances(&self) -> String {
        match self.instances().await {
            Ok(instances) => serde_json::to_string(&instances).unwrap_or_else(|error| {
                serde_json::json!({ "error": error.to_string() }).to_string()
            }),
            Err(error) => serde_json::json!({ "error": error.to_string() }).to_string(),
        }
    }

    #[tool(description = "Resolve one active Neovim instance by instanceId or absolute file path.")]
    async fn resolve_instance(
        &self,
        Parameters(params): Parameters<ResolveInstanceParams>,
    ) -> String {
        match self.instances().await {
            Ok(instances) => match resolve_instance(
                &instances.instances,
                params.instance_id.as_deref(),
                params.uri.as_deref(),
            ) {
                Ok(instance) => serde_json::to_string(instance).unwrap_or_else(|error| {
                    serde_json::json!({ "error": error.to_string() }).to_string()
                }),
                Err(error) => serde_json::json!({ "error": error.to_string() }).to_string(),
            },
            Err(error) => serde_json::json!({ "error": error.to_string() }).to_string(),
        }
    }

    #[tool(
        description = r#"Execute an LSP operation through the Neovim instance matching `uri`.

PATHS AND POSITIONS
- Pass a native absolute path. Unix: /home/user/file.ts. Windows: C:/work/file.ts.
- Plain paths are recommended; do not manually construct file:// URIs.
- Input and output positions are 1-based. Output range `45:17-45:32` can be reused as line=45, character=17.
- Do not guess symbol positions. For a known file, call document_symbols first. For a project search, call workspace_symbols with query.

CHOOSE BY INTENT
No position required:
- document_symbols: outline symbols in one file.
- workspace_symbols: search project symbols; requires query.
- diagnostics: diagnostics for one file.
- workspace_diagnostics: diagnostics under a workspace path.

Symbol position required:
- hover: signature and documentation.
- definition, declaration, type_definition, implementation: navigation locations.
- references: project references grouped by file.
- document_highlight: semantic occurrences in the current document.
- code_actions: fixes and refactors available at a position.

Call-site position required:
- signature_help: pass a position inside the intended call argument.

SAFE WRITE FLOWS
- Rename: prepare_rename -> rename_preview(newName) -> rename_apply(renameId).
- Specific fix: code_actions -> code_action_preview(actionId) -> code_action_apply(actionId).
- Whole-file quick fixes: file_quickfix_preview -> code_action_apply(actionId).

Preview operations never modify files. Apply operations save to disk and reject stale, expired, reused, or overlapping edits. Command-only code actions are not executed. List results are compact and limited by max-results."#
    )]
    async fn lsp(&self, Parameters(params): Parameters<LspParams>) -> String {
        match self.run_lsp(&params).await {
            Ok(result) => self.output.format_lsp(params.operation.as_str(), result),
            Err(error) => self.output.format_lsp(
                params.operation.as_str(),
                serde_json::json!({
                  "error": {
                    "code": "request_failed",
                    "message": error,
                  },
                }),
            ),
        }
    }

    #[tool(description = "Report the vv-mcp server and registry status.")]
    async fn health(&self) -> String {
        serde_json::json!({
          "status": "ok",
          "registry": self.registry.dir(),
          "outputFormat": self.output.format,
          "maxResults": self.output.max_results,
        })
        .to_string()
    }
}

impl VvMcpServer {
    async fn run_lsp(&self, params: &LspParams) -> Result<Value, String> {
        let mut last_error = None;

        for attempt in 0..2 {
            let instance = self.select_instance(params).await?;
            match self.request_lsp(&instance, params).await {
                Ok(result) => return Ok(result),
                Err(error) if attempt == 0 && error.proves_instance_is_stale() => {
                    last_error = Some(error.to_string());
                }
                Err(error) => return Err(error.to_string()),
            }
        }

        Err(last_error.unwrap_or_else(|| "Neovim instance became unavailable".into()))
    }

    async fn select_instance(&self, params: &LspParams) -> Result<Instance, String> {
        let instances = self.instances().await.map_err(|error| error.to_string())?;
        resolve_instance(
            &instances.instances,
            params.instance_id.as_deref(),
            Some(&params.uri),
        )
        .cloned()
        .map_err(|error| error.to_string())
    }

    async fn request_lsp(
        &self,
        instance: &Instance,
        params: &LspParams,
    ) -> Result<Value, NvimError> {
        let mut client = NvimClient::connect(&instance.socket).await?;
        let rpc_timeout = rpc_timeout(params.timeout_ms);
        let params = serde_json::to_value(params)
            .map_err(|error| NvimError::MessagePack(error.to_string()))?;
        client
            .exec_lua_with_timeout(LSP_REQUEST, vec![params], rpc_timeout)
            .await
    }
}

fn rpc_timeout(timeout_ms: Option<u32>) -> Duration {
    Duration::from_millis(
        u64::from(timeout_ms.unwrap_or(DEFAULT_LSP_TIMEOUT_MS))
            .saturating_add(RPC_TIMEOUT_MARGIN_MS),
    )
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
struct ResolveInstanceParams {
    /// Exact instance ID returned by list_instances.
    instance_id: Option<String>,
    /// Absolute Unix or Windows file path used for automatic workspace matching.
    uri: Option<String>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
struct LspParams {
    /// LSP operation to execute. Some apply operations write edits to disk; follow the safe write flows in the tool description.
    operation: LspOperation,
    /// Native absolute Unix or Windows path, such as /home/user/file.ts or C:/work/file.ts. Plain paths are recommended; a file URI is accepted for compatibility.
    uri: String,
    /// 1-based line. Required only for position-based operations. Reuse the range start returned by document_symbols or workspace_symbols instead of counting manually.
    line: Option<u32>,
    /// 1-based character. Required only for position-based operations. Reuse a symbol range start; signature_help instead needs a position inside the intended call argument.
    character: Option<u32>,
    /// Exact instance ID from list_instances. Usually omit it to route automatically by uri; provide it to disambiguate overlapping instances.
    instance_id: Option<String>,
    /// Non-empty symbol search query. Required only for workspace_symbols.
    query: Option<String>,
    /// New symbol name. Required only for rename_preview.
    new_name: Option<String>,
    /// Transaction ID returned by rename_preview. Required only for rename_apply.
    rename_id: Option<String>,
    /// Code action ID. A candidate from code_actions must be passed to code_action_preview before apply; file_quickfix_preview returns an already previewed transaction ID.
    action_id: Option<String>,
    /// Optional code action kind filter for code_actions, such as quickfix or refactor.extract.
    action_kind: Option<String>,
    /// Optional Neovim-side LSP request timeout in milliseconds for unusually slow language servers.
    timeout_ms: Option<u32>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
enum LspOperation {
    Definition,
    Declaration,
    TypeDefinition,
    Implementation,
    References,
    DocumentHighlight,
    Hover,
    SignatureHelp,
    DocumentSymbols,
    WorkspaceSymbols,
    Diagnostics,
    WorkspaceDiagnostics,
    CodeActions,
    CodeActionPreview,
    FileQuickfixPreview,
    CodeActionApply,
    PrepareRename,
    RenamePreview,
    RenameApply,
}

impl LspOperation {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Definition => "definition",
            Self::Declaration => "declaration",
            Self::TypeDefinition => "type_definition",
            Self::Implementation => "implementation",
            Self::References => "references",
            Self::DocumentHighlight => "document_highlight",
            Self::Hover => "hover",
            Self::SignatureHelp => "signature_help",
            Self::DocumentSymbols => "document_symbols",
            Self::WorkspaceSymbols => "workspace_symbols",
            Self::Diagnostics => "diagnostics",
            Self::WorkspaceDiagnostics => "workspace_diagnostics",
            Self::CodeActions => "code_actions",
            Self::CodeActionPreview => "code_action_preview",
            Self::FileQuickfixPreview => "file_quickfix_preview",
            Self::CodeActionApply => "code_action_apply",
            Self::PrepareRename => "prepare_rename",
            Self::RenamePreview => "rename_preview",
            Self::RenameApply => "rename_apply",
        }
    }
}

#[tool_handler]
impl ServerHandler for VvMcpServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("vv-mcp", env!("CARGO_PKG_VERSION")))
            .with_instructions(
                "Pass native absolute paths and 1-based positions. Omit instanceId for automatic routing by uri; use list_instances only to inspect or disambiguate projects. When a symbol position is uncertain, locate it with document_symbols for a known file or workspace_symbols for a project query, then reuse the returned range start. For writes, always follow the preview-to-apply flow described by the lsp tool.",
            )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rpc_timeout_exceeds_inner_lsp_timeout() {
        assert_eq!(rpc_timeout(None), Duration::from_millis(4000));
        assert_eq!(rpc_timeout(Some(7500)), Duration::from_millis(8500));
    }
}
