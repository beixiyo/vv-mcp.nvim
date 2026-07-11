//! 实例注册文件与 MCP 实例列表的数据模型

use serde::{Deserialize, Serialize};

/// 单个运行中 Neovim 实例发布的元数据
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

/// `list_instances` MCP 工具返回的实例集合
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstanceList {
    pub instances: Vec<Instance>,
}
