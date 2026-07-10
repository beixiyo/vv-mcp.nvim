use serde::{Deserialize, Serialize};

/// Metadata published by one running Neovim instance.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Instance {
    pub instance_id: String,
    pub project_id: String,
    pub pid: u32,
    pub socket: String,
    pub cwd: String,
    pub roots: Vec<String>,
    pub lsp_clients: Vec<String>,
    pub updated_at: u64,
}

/// Result returned by the `list_instances` MCP tool.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstanceList {
    pub instances: Vec<Instance>,
}
