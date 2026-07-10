use std::path::PathBuf;

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
};

const LSP_REQUEST: &str = "return require('vv-mcp.lsp').request(...)";

#[derive(Clone, Debug)]
pub struct VvMcpServer {
    registry: Registry,
}

#[tool_router]
impl VvMcpServer {
    pub fn new(registry: Option<PathBuf>) -> Result<Self> {
        Ok(Self {
            registry: Registry::new(registry)?,
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
        description = "Run a read-only LSP operation through the matching Neovim instance. Paths use standard absolute Unix or Windows syntax; line and character are 1-based."
    )]
    async fn lsp(&self, Parameters(params): Parameters<LspParams>) -> String {
        match self.run_lsp(&params).await {
            Ok(result) => serde_json::to_string(&result).unwrap_or_else(json_error),
            Err(error) => json_error(error),
        }
    }

    #[tool(description = "Report the vv-mcp server and registry status.")]
    async fn health(&self) -> String {
        serde_json::json!({
          "status": "ok",
          "registry": self.registry.dir(),
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
        let params = serde_json::to_value(params)
            .map_err(|error| NvimError::MessagePack(error.to_string()))?;
        client.exec_lua(LSP_REQUEST, vec![params]).await
    }
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
    /// Read-only LSP operation to execute.
    operation: LspOperation,
    /// Absolute Unix or Windows file path. A file URI is accepted for compatibility.
    uri: String,
    /// 1-based line number.
    line: u32,
    /// 1-based character offset.
    character: u32,
    /// Exact instance ID from list_instances. Omit to match by path.
    instance_id: Option<String>,
    /// Reserved for operations such as workspace_symbols.
    query: Option<String>,
    /// Neovim-side LSP request timeout in milliseconds.
    timeout_ms: Option<u32>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
enum LspOperation {
    Definition,
    Declaration,
    Implementation,
    References,
}

fn json_error(error: impl ToString) -> String {
    serde_json::json!({
      "error": {
        "code": "request_failed",
        "message": error.to_string(),
      },
    })
    .to_string()
}

#[tool_handler]
impl ServerHandler for VvMcpServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("vv-mcp", env!("CARGO_PKG_VERSION")))
            .with_instructions("Use list_instances before calling project-scoped LSP tools.")
    }
}
