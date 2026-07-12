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
const WORKSPACE_REQUEST: &str = "return require('vv-mcp.workspace').request(...)";
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
    pub async fn fix_document(
        &self,
        uri: String,
        instance_id: Option<String>,
        timeout_ms: u32,
        line: Option<u32>,
    ) -> Result<Value, String> {
        let params = fix_params(uri, instance_id, timeout_ms, line);
        self.run_lsp(&params).await
    }

    /// 解析并固定 CLI 批处理使用的底层 Neovim 连接
    pub async fn resolve_active_instance(
        &self,
        uri: &str,
        instance_id: Option<&str>,
    ) -> Result<Instance, String> {
        let instances = self.instances().await.map_err(|error| error.to_string())?;
        resolve_instance(&instances.instances, instance_id, Some(uri))
            .cloned()
            .map_err(|error| error.to_string())
    }

    /// 通过已经固定的 Neovim socket 修复文档，不在文件之间重新解析注册表
    pub async fn fix_document_on_instance(
        &self,
        instance: &Instance,
        uri: String,
        timeout_ms: u32,
    ) -> Result<Value, String> {
        let params = fix_params(uri, Some(instance.instance_id.clone()), timeout_ms, None);
        self.request_lsp(instance, &params)
            .await
            .map_err(|error| error.to_string())
    }

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
        let raw = match self.run_editor(&params).await {
            Ok(raw) => raw,
            Err(error) => serde_json::json!({
                "error": { "code": "request_failed", "message": error }
            }),
        };
        self.output.format_editor(params.operation_name(), raw)
    }

    #[tool(
        description = r#"Safely rename a file or directory inside one Neovim workspace.

OPERATIONS
- rename_resource_preview: requires oldUri and newUri. Collects workspace/willRenameFiles edits, validates paths and live buffers, and returns a single-use resourceRenameId without modifying files.
- rename_resource_apply: requires resourceRenameId and the same instanceId used for preview. Revalidates the transaction, applies import/reference edits, renames the resource on disk, synchronizes loaded buffers, saves edits, and sends workspace/didRenameFiles.

Both paths must be absolute and remain inside one workspace root. Modified buffers under the source path must be saved before preview. Apply rejects stale, expired, reused, conflicting, or unsupported resource edits."#
    )]
    async fn workspace(&self, Parameters(params): Parameters<WorkspaceParams>) -> String {
        match self.run_workspace(&params).await {
            Ok(result) => self
                .output
                .format_workspace(params.operation.as_str(), result),
            Err(error) => self.output.format_workspace(
                params.operation.as_str(),
                serde_json::json!({
                  "error": { "code": "request_failed", "message": error }
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
    /// 按配置的输出格式渲染一次 LSP 结果，CLI 与 MCP 工具共用同一套格式化
    pub fn format_lsp(&self, operation: &str, raw: Value) -> String {
        self.output.format_lsp(operation, raw)
    }

    /// 按配置的输出格式渲染一次编辑器状态结果
    pub fn format_editor(&self, operation: &str, raw: Value) -> String {
        self.output.format_editor(operation, raw)
    }

    pub async fn run_lsp(&self, params: &LspParams) -> Result<Value, String> {
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
        self.resolve_active_instance(&params.uri, params.instance_id.as_deref())
            .await
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

    pub async fn run_editor(&self, params: &EditorParams) -> Result<Value, String> {
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
                .exec_lua_with_timeout(EDITOR_REQUEST, vec![value], rpc_timeout(params.timeout_ms))
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

    async fn run_workspace(&self, params: &WorkspaceParams) -> Result<Value, String> {
        params.validate()?;
        let instances = self.instances().await.map_err(|error| error.to_string())?;
        let instance = resolve_instance(
            &instances.instances,
            params.instance_id.as_deref(),
            params.old_uri.as_deref(),
        )
        .cloned()
        .map_err(|error| error.to_string())?;
        let mut client = NvimClient::connect(&instance.socket)
            .await
            .map_err(|error| error.to_string())?;
        let value = serde_json::to_value(params).map_err(|error| error.to_string())?;
        client
            .exec_lua_with_timeout(WORKSPACE_REQUEST, vec![value], Duration::from_secs(7))
            .await
            .map_err(|error| error.to_string())
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

/// 编辑器只读状态参数：与 `LspParams` 一样，一份定义同时驱动 MCP schema、线上负载与命令行
#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, clap::Args)]
#[serde(rename_all = "camelCase")]
pub struct EditorParams {
    /// Editor state to read
    #[arg(long, value_enum)]
    operation: EditorOperation,
    /// Instance ID from `list_instances`; required for current-state operations
    /// On CLI, injected as a global option by `set_routing`
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(skip)]
    instance_id: Option<String>,
    /// Optional timeout in milliseconds on Neovim side
    /// On CLI, injected as a global option by `set_routing`
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(skip)]
    timeout_ms: Option<u32>,
    /// Native Unix or Windows absolute path for `read_buffer`
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(long)]
    uri: Option<String>,
    /// Optional start line for `read_buffer`, 1-based inclusive
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(long)]
    start_line: Option<u32>,
    /// Optional end line for `read_buffer`, 1-based inclusive
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(long)]
    end_line: Option<u32>,
    /// Maximum lines returned for `read_buffer`, defaults to 200
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(long)]
    max_lines: Option<u32>,
    /// Include plugin, terminal, help, and other special buffers in `list_buffers`; defaults to false
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(long, num_args = 0..=1, default_missing_value = "true")]
    include_special: Option<bool>,
}

impl EditorParams {
    /// 线上使用的操作名，同时用于挑选输出格式化器
    pub fn operation_name(&self) -> &'static str {
        self.operation.as_str()
    }

    /// 注入命令行上的全局路由参数：实例选择与超时对每个子命令都生效
    pub fn set_routing(&mut self, instance_id: Option<String>, timeout_ms: Option<u32>) {
        self.instance_id = instance_id;
        self.timeout_ms = timeout_ms;
    }

    pub fn uri(&self) -> Option<&str> {
        self.uri.as_deref()
    }

    pub fn set_uri(&mut self, uri: String) {
        self.uri = Some(uri);
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, schemars::JsonSchema, clap::ValueEnum)]
#[serde(rename_all = "snake_case")]
#[value(rename_all = "snake_case")]
enum EditorOperation {
    CurrentContext,
    ListBuffers,
    ReadBuffer,
    GetSelection,
}

impl EditorOperation {
    fn as_str(&self) -> &'static str {
        match self {
            Self::CurrentContext => "current_context",
            Self::ListBuffers => "list_buffers",
            Self::ReadBuffer => "read_buffer",
            Self::GetSelection => "get_selection",
        }
    }
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
struct WorkspaceParams {
    /// 要执行的工作区资源操作
    operation: WorkspaceOperation,
    /// 预览阶段的源文件或目录绝对路径
    #[serde(skip_serializing_if = "Option::is_none")]
    old_uri: Option<String>,
    /// 预览阶段的目标文件或目录绝对路径
    #[serde(skip_serializing_if = "Option::is_none")]
    new_uri: Option<String>,
    /// rename_resource_preview 返回的单次事务 ID
    #[serde(skip_serializing_if = "Option::is_none")]
    resource_rename_id: Option<String>,
    /// list_instances 返回的实例 ID；apply 阶段必须复用 preview 所在实例
    #[serde(skip_serializing_if = "Option::is_none")]
    instance_id: Option<String>,
    /// 等待 LSP willRenameFiles 响应的超时时间，默认 5000ms
    #[serde(skip_serializing_if = "Option::is_none")]
    timeout_ms: Option<u32>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
enum WorkspaceOperation {
    RenameResourcePreview,
    RenameResourceApply,
}

impl WorkspaceOperation {
    fn as_str(&self) -> &'static str {
        match self {
            Self::RenameResourcePreview => "rename_resource_preview",
            Self::RenameResourceApply => "rename_resource_apply",
        }
    }
}

impl WorkspaceParams {
    fn validate(&self) -> Result<(), String> {
        match self.operation {
            WorkspaceOperation::RenameResourcePreview => {
                if self.old_uri.as_deref().is_none_or(str::is_empty)
                    || self.new_uri.as_deref().is_none_or(str::is_empty)
                {
                    return Err("oldUri and newUri are required for rename_resource_preview".into());
                }
            }
            WorkspaceOperation::RenameResourceApply => {
                if self.resource_rename_id.as_deref().is_none_or(str::is_empty) {
                    return Err("resourceRenameId is required for rename_resource_apply".into());
                }
                if self.instance_id.as_deref().is_none_or(str::is_empty) {
                    return Err(
                        "instanceId from rename_resource_preview is required for rename_resource_apply"
                            .into(),
                    );
                }
            }
        }
        Ok(())
    }
}

/// LSP 请求参数：同一份定义同时驱动 MCP schema（schemars）、线上负载（serde）与命令行（clap）
///
/// 新增字段只需写一次：serde 生成 camelCase 的 JSON 字段，clap 生成 kebab-case 的长选项，
/// 字段上的文档注释同时作为 MCP description 与 `--help` 文案，两个面不会漂移
#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, clap::Args)]
#[serde(rename_all = "camelCase")]
pub struct LspParams {
    /// LSP operation to execute; some apply operations write to disk and must follow the safe write flow
    #[arg(long, value_enum)]
    operation: LspOperation,
    /// Native Unix or Windows absolute path; plain paths recommended, also accepts file URIs
    #[arg(long)]
    uri: String,
    /// 1-based line number; required for position operations, prefer reusing range start from symbol queries
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(long)]
    line: Option<u32>,
    /// 1-based column number; `signature_help` must pass a position inside the target call argument
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(long)]
    character: Option<u32>,
    /// Instance ID from `list_instances`; usually omitted for automatic routing by uri, disambiguates overlapping instances
    /// On CLI, injected as a global option by `set_routing`
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(skip)]
    instance_id: Option<String>,
    /// Symbol search query; required for `workspace_symbols`, optional for `document_symbols` (case-insensitive)
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(long)]
    query: Option<String>,
    /// Optional symbol kind filter for `document_symbols`
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(long, value_enum, value_delimiter = ',')]
    symbol_kinds: Option<Vec<SymbolKindFilter>>,
    /// New symbol name; required only for `rename_preview`
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(long)]
    new_name: Option<String>,
    /// Transaction ID from `rename_preview`; required only for `rename_apply`
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(long)]
    rename_id: Option<String>,
    /// Code Action ID; candidate actions must be previewed first, full-document fix IDs skip preview
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(long)]
    action_id: Option<String>,
    /// Optional kind filter for `code_actions`, e.g. `quickfix` or `refactor.extract`
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(long)]
    action_kind: Option<String>,
    /// Optional timeout in milliseconds on Neovim side for slower language servers
    /// On CLI, injected as a global option by `set_routing`
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(skip)]
    timeout_ms: Option<u32>,
    /// Optional start line for `inlay_hints`, 1-based; omit to start from file beginning
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(long)]
    start_line: Option<u32>,
    /// Optional end line for `inlay_hints`, 1-based inclusive; omit to read entire file
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(long)]
    end_line: Option<u32>,
    /// Call hierarchy node ID; returned by prepare or previous level query
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(long)]
    call_id: Option<String>,
    /// Include symbol declarations in `references`; defaults to true
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(long, num_args = 0..=1, default_missing_value = "true")]
    include_declaration: Option<bool>,
    /// Optional severity filter for `diagnostics` and `workspace_diagnostics`
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(long, value_enum, value_delimiter = ',')]
    severities: Option<Vec<DiagnosticSeverityFilter>>,
    /// Optional source filter for `diagnostics` and `workspace_diagnostics`
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(long, value_delimiter = ',')]
    sources: Option<Vec<String>>,
    /// Optional diagnostic code filter for `diagnostics` and `workspace_diagnostics`; numeric codes match as strings
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(long, value_delimiter = ',')]
    codes: Option<Vec<String>>,
    /// Include dependencies and external results in `references`, `incoming_calls`, and `outgoing_calls`; defaults to true
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(long, num_args = 0..=1, default_missing_value = "true")]
    include_external: Option<bool>,
    /// Optional path substring filter for `references`; use plain Unix path fragments, not glob or regex
    #[serde(skip_serializing_if = "Option::is_none")]
    #[arg(long)]
    path_pattern: Option<String>,
    /// Clean up temporary buffers created by this request after CLI batch processing; not included in MCP schema or CLI
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(skip)]
    #[arg(skip)]
    cleanup_temporary: Option<bool>,
}

impl LspParams {
    /// 线上使用的操作名，同时用于挑选输出格式化器
    pub fn operation_name(&self) -> &'static str {
        self.operation.as_str()
    }

    /// 注入命令行上的全局路由参数：实例选择与超时对每个子命令都生效
    pub fn set_routing(&mut self, instance_id: Option<String>, timeout_ms: Option<u32>) {
        self.instance_id = instance_id;
        self.timeout_ms = timeout_ms;
    }

    pub fn uri(&self) -> &str {
        &self.uri
    }

    pub fn set_uri(&mut self, uri: String) {
        self.uri = uri;
    }

    /// 该操作是否会写入磁盘；CLI 对这些操作要求显式 `--yes`
    pub fn writes_to_disk(&self) -> bool {
        matches!(
            self.operation,
            LspOperation::FixDocument | LspOperation::CodeActionApply | LspOperation::RenameApply
        )
    }

    fn document(
        operation: LspOperation,
        uri: String,
        instance_id: Option<String>,
        timeout_ms: Option<u32>,
    ) -> Self {
        Self {
            operation,
            uri,
            line: None,
            character: None,
            instance_id,
            query: None,
            symbol_kinds: None,
            new_name: None,
            rename_id: None,
            action_id: None,
            action_kind: None,
            timeout_ms,
            start_line: None,
            end_line: None,
            call_id: None,
            include_declaration: None,
            severities: None,
            sources: None,
            codes: None,
            include_external: None,
            path_pattern: None,
            cleanup_temporary: None,
        }
    }
}

/// 构造一次自动修复请求：可选行号，并让 Neovim 清理本次请求临时创建的 buffer
fn fix_params(
    uri: String,
    instance_id: Option<String>,
    timeout_ms: u32,
    line: Option<u32>,
) -> LspParams {
    let mut params = LspParams::document(
        LspOperation::FixDocument,
        uri,
        instance_id,
        Some(timeout_ms),
    );
    params.line = line;
    params.character = line.map(|_| 1);
    params.cleanup_temporary = Some(true);
    params
}

#[derive(Clone, Debug, Deserialize, Serialize, schemars::JsonSchema, clap::ValueEnum)]
#[serde(rename_all = "lowercase")]
#[value(rename_all = "lower")]
enum DiagnosticSeverityFilter {
    Error,
    Warning,
    Information,
    Hint,
}

#[derive(Clone, Debug, Deserialize, Serialize, schemars::JsonSchema, clap::ValueEnum)]
#[serde(rename_all = "snake_case")]
#[value(rename_all = "snake_case")]
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

#[derive(Clone, Debug, Deserialize, Serialize, schemars::JsonSchema, clap::ValueEnum)]
#[serde(rename_all = "snake_case")]
#[value(rename_all = "snake_case")]
pub enum LspOperation {
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
    FixDocument,
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
            Self::FixDocument => "fix_document",
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
                "Pass native absolute paths and 1-based positions. Omit instanceId for automatic routing by uri; use list_instances only to inspect or disambiguate projects. When a symbol position is uncertain, locate it with document_symbols for a known file or workspace_symbols for a project query, then reuse the returned range start. For writes, always follow the preview-to-apply flow described by the lsp or workspace tool.",
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
            cleanup_temporary: None,
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

    #[test]
    fn validates_resource_rename_stage_requirements() {
        let preview = WorkspaceParams {
            operation: WorkspaceOperation::RenameResourcePreview,
            old_uri: Some("/code/old.ts".into()),
            new_uri: Some("/code/new.ts".into()),
            resource_rename_id: None,
            instance_id: None,
            timeout_ms: None,
        };
        assert!(preview.validate().is_ok());

        let apply_without_instance = WorkspaceParams {
            operation: WorkspaceOperation::RenameResourceApply,
            old_uri: None,
            new_uri: None,
            resource_rename_id: Some("rename-1".into()),
            instance_id: None,
            timeout_ms: None,
        };
        assert_eq!(
            apply_without_instance.validate().unwrap_err(),
            "instanceId from rename_resource_preview is required for rename_resource_apply"
        );
    }
}
