//! MCP Server 定义：注册工具、生成输入 Schema，并将 LSP 请求转发给匹配的 Neovim 实例

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
const EDITOR_REQUEST: &str = "return require('vv-mcp.editor').request(...)";
const DEFAULT_LSP_TIMEOUT_MS: u32 = 3000;
const RPC_TIMEOUT_MARGIN_MS: u64 = 1000;

#[derive(Clone, Debug)]
/// vv-mcp 服务实例，持有实例注册表与输出压缩配置
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
- document_symbols: outline symbols in one file; optional query and symbolKinds filters.
- workspace_symbols: search project symbols; requires query.
- diagnostics: diagnostics for one file; optional severities, sources, and codes filters.
- workspace_diagnostics: diagnostics under a workspace path; optional severities, sources, and codes filters.
- document_links: navigable targets in one document.
- inlay_hints: inferred types and parameter-name hints; optionally accepts startLine and endLine.
- prepare_call_hierarchy: create call graph nodes at a symbol position and return callId values.
- incoming_calls, outgoing_calls: query one graph layer by callId; returned nodes include new callId values for further traversal; set includeExternal=false for workspace-only nodes.

Symbol position required:
- hover: signature and documentation.
- definition, declaration, type_definition, implementation: navigation locations.
- references: project references grouped by file; includeDeclaration defaults to true. Set includeExternal=false to keep workspace files, or pathPattern to match a normalized path substring.
- document_highlight: semantic occurrences in the current document.
- code_actions: fixes and refactors available at a position.

Call-site position required:
- signature_help: pass a position inside the intended call argument.

SAFE WRITE FLOWS
- Rename: prepare_rename -> rename_preview(newName) -> rename_apply(renameId).
- Specific fix: code_actions -> code_action_preview(actionId) -> code_action_apply(actionId).
- Fix a document: fix_document_preview -> code_action_apply(actionId). It prefers each LSP's source.fixAll and falls back to diagnostic quick fixes.

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

    #[tool(
        description = r#"Read live editor state from one Neovim instance without modifying buffers or files.

OPERATIONS
- current_context: current buffer, cursor, mode, cwd, window, tab, filetype, modified state, and attached LSP clients. Pass instanceId.
- list_buffers: editable loaded file buffers with visibility, modified state, line count, filetype, and attached LSP clients. Pass instanceId; set includeSpecial=true to include plugin, terminal, help, and other special buffers.
- read_buffer: read live buffer text, including unsaved changes. Pass uri; startLine/endLine are optional 1-based inclusive bounds. maxLines defaults to 200.
- get_selection: current Visual, Visual Line, or Visual Block selection with 1-based range and selected text. Pass instanceId.

Use list_instances first when more than one Neovim project is running. read_buffer can route automatically by uri; current-state operations require instanceId because they have no file path to disambiguate. This tool is read-only."#
    )]
    async fn editor(&self, Parameters(params): Parameters<EditorParams>) -> String {
        match self.run_editor(&params).await {
            Ok(result) => serde_json::to_string(&result).unwrap_or_else(|error| {
                serde_json::json!({ "error": { "code": "serialization_failed", "message": error.to_string() } }).to_string()
            }),
            Err(error) => serde_json::json!({
                "error": { "code": "request_failed", "message": error }
            })
            .to_string(),
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

    async fn run_editor(&self, params: &EditorParams) -> Result<Value, String> {
        let mut last_error = None;
        for attempt in 0..2 {
            let instances = self.instances().await.map_err(|error| error.to_string())?;
            let instance = resolve_instance(
                &instances.instances,
                params.instance_id.as_deref(),
                params.uri.as_deref(),
            )
            .cloned()
            .map_err(|error| error.to_string())?;
            let mut client = match NvimClient::connect(&instance.socket).await {
                Ok(client) => client,
                Err(error) if attempt == 0 && error.proves_instance_is_stale() => {
                    last_error = Some(error.to_string());
                    continue;
                }
                Err(error) => return Err(error.to_string()),
            };
            let value = serde_json::to_value(params).map_err(|error| error.to_string())?;
            match client
                .exec_lua_with_timeout(EDITOR_REQUEST, vec![value], Duration::from_secs(4))
                .await
            {
                Ok(result) => return Ok(result),
                Err(error) if attempt == 0 && error.proves_instance_is_stale() => {
                    last_error = Some(error.to_string());
                }
                Err(error) => return Err(error.to_string()),
            }
        }
        Err(last_error.unwrap_or_else(|| "Neovim instance became unavailable".into()))
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
    /// `list_instances` 返回的精确实例 ID
    instance_id: Option<String>,
    /// 用于自动匹配工作区的 Unix 或 Windows 绝对路径
    uri: Option<String>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
struct EditorParams {
    /// 要读取的编辑器状态
    operation: EditorOperation,
    /// `list_instances` 返回的实例 ID；当前状态操作必须提供
    #[serde(skip_serializing_if = "Option::is_none")]
    instance_id: Option<String>,
    /// `read_buffer` 要读取的原生 Unix 或 Windows 绝对路径
    #[serde(skip_serializing_if = "Option::is_none")]
    uri: Option<String>,
    /// `read_buffer` 的可选起始行，从 1 开始且包含该行
    #[serde(skip_serializing_if = "Option::is_none")]
    start_line: Option<u32>,
    /// `read_buffer` 的可选结束行，从 1 开始且包含该行
    #[serde(skip_serializing_if = "Option::is_none")]
    end_line: Option<u32>,
    /// `read_buffer` 最多返回的行数，默认为 200
    #[serde(skip_serializing_if = "Option::is_none")]
    max_lines: Option<u32>,
    /// `list_buffers` 是否包含插件、终端、帮助页等特殊 buffer，默认为 false
    #[serde(skip_serializing_if = "Option::is_none")]
    include_special: Option<bool>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
enum EditorOperation {
    CurrentContext,
    ListBuffers,
    ReadBuffer,
    GetSelection,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
struct LspParams {
    /// 要执行的 LSP 操作；部分 apply 操作会写入磁盘，必须遵循工具描述中的安全写入流程
    operation: LspOperation,
    /// 原生 Unix 或 Windows 绝对路径；推荐普通路径，同时兼容 file URI
    uri: String,
    /// 从 1 开始的行号；仅位置操作需要，优先复用符号查询返回的 range 起点
    #[serde(skip_serializing_if = "Option::is_none")]
    line: Option<u32>,
    /// 从 1 开始的列号；`signature_help` 必须传入目标调用参数内部的位置
    #[serde(skip_serializing_if = "Option::is_none")]
    character: Option<u32>,
    /// `list_instances` 返回的实例 ID；通常省略并按 uri 自动路由，实例重叠时用于消歧
    #[serde(skip_serializing_if = "Option::is_none")]
    instance_id: Option<String>,
    /// 非空符号搜索词；`workspace_symbols` 必填，`document_symbols` 可选且忽略大小写
    #[serde(skip_serializing_if = "Option::is_none")]
    query: Option<String>,
    /// `document_symbols` 的可选符号类别筛选
    #[serde(skip_serializing_if = "Option::is_none")]
    symbol_kinds: Option<Vec<SymbolKindFilter>>,
    /// 新符号名，仅 `rename_preview` 需要
    #[serde(skip_serializing_if = "Option::is_none")]
    new_name: Option<String>,
    /// `rename_preview` 返回的事务 ID，仅 `rename_apply` 需要
    #[serde(skip_serializing_if = "Option::is_none")]
    rename_id: Option<String>,
    /// Code Action ID；候选动作必须先预览，全文件修复操作返回的 ID 已完成预览
    #[serde(skip_serializing_if = "Option::is_none")]
    action_id: Option<String>,
    /// `code_actions` 的可选 kind 过滤器，例如 `quickfix` 或 `refactor.extract`
    #[serde(skip_serializing_if = "Option::is_none")]
    action_kind: Option<String>,
    /// Neovim 侧可选超时时间，用于响应较慢的语言服务器
    #[serde(skip_serializing_if = "Option::is_none")]
    timeout_ms: Option<u32>,
    /// `inlay_hints` 的可选起始行，从 1 开始；省略时从文件首行开始
    #[serde(skip_serializing_if = "Option::is_none")]
    start_line: Option<u32>,
    /// `inlay_hints` 的可选结束行，从 1 开始且包含该行；省略时读取整个文件
    #[serde(skip_serializing_if = "Option::is_none")]
    end_line: Option<u32>,
    /// 调用层级节点 ID；由 prepare 或上一层调用结果返回
    #[serde(skip_serializing_if = "Option::is_none")]
    call_id: Option<String>,
    /// `references` 是否包含符号声明，默认为 true
    #[serde(skip_serializing_if = "Option::is_none")]
    include_declaration: Option<bool>,
    /// `diagnostics` 与 `workspace_diagnostics` 的可选严重级别筛选
    #[serde(skip_serializing_if = "Option::is_none")]
    severities: Option<Vec<DiagnosticSeverityFilter>>,
    /// `diagnostics` 与 `workspace_diagnostics` 的可选 source 筛选
    #[serde(skip_serializing_if = "Option::is_none")]
    sources: Option<Vec<String>>,
    /// `diagnostics` 与 `workspace_diagnostics` 的可选诊断 code 筛选，数字 code 也按字符串匹配
    #[serde(skip_serializing_if = "Option::is_none")]
    codes: Option<Vec<String>>,
    /// `references`、`incoming_calls` 与 `outgoing_calls` 是否包含依赖和工作区外结果，默认为 true
    #[serde(skip_serializing_if = "Option::is_none")]
    include_external: Option<bool>,
    /// `references` 的可选路径子串筛选；使用普通 Unix 路径片段，不是 glob 或正则
    #[serde(skip_serializing_if = "Option::is_none")]
    path_pattern: Option<String>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "lowercase")]
enum DiagnosticSeverityFilter {
    Error,
    Warning,
    Information,
    Hint,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
enum SymbolKindFilter {
    File,
    Module,
    Namespace,
    Package,
    Class,
    Method,
    Property,
    Field,
    Constructor,
    Enum,
    Interface,
    Function,
    Variable,
    Constant,
    String,
    Number,
    Boolean,
    Array,
    Object,
    Key,
    Null,
    EnumMember,
    Struct,
    Event,
    Operator,
    TypeParameter,
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
    DocumentLinks,
    InlayHints,
    PrepareCallHierarchy,
    IncomingCalls,
    OutgoingCalls,
    DocumentSymbols,
    WorkspaceSymbols,
    Diagnostics,
    WorkspaceDiagnostics,
    CodeActions,
    CodeActionPreview,
    FixDocumentPreview,
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
            Self::DocumentLinks => "document_links",
            Self::InlayHints => "inlay_hints",
            Self::PrepareCallHierarchy => "prepare_call_hierarchy",
            Self::IncomingCalls => "incoming_calls",
            Self::OutgoingCalls => "outgoing_calls",
            Self::DocumentSymbols => "document_symbols",
            Self::WorkspaceSymbols => "workspace_symbols",
            Self::Diagnostics => "diagnostics",
            Self::WorkspaceDiagnostics => "workspace_diagnostics",
            Self::CodeActions => "code_actions",
            Self::CodeActionPreview => "code_action_preview",
            Self::FixDocumentPreview => "fix_document_preview",
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

    #[test]
    fn omits_absent_optional_lsp_params() {
        let params = LspParams {
            operation: LspOperation::InlayHints,
            uri: "/code/file.ts".into(),
            line: None,
            character: None,
            instance_id: None,
            query: None,
            symbol_kinds: None,
            new_name: None,
            rename_id: None,
            action_id: None,
            action_kind: None,
            timeout_ms: None,
            start_line: None,
            end_line: None,
            call_id: None,
            include_declaration: None,
            severities: None,
            sources: None,
            codes: None,
            include_external: None,
            path_pattern: None,
        };
        let value = serde_json::to_value(params).unwrap();

        assert_eq!(
            value,
            serde_json::json!({
                "operation": "inlay_hints",
                "uri": "/code/file.ts"
            })
        );
    }
}
