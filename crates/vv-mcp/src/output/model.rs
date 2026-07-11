//! 多种输出格式共享的紧凑数据模型

use std::collections::BTreeMap;

use serde::Serialize;

#[derive(Debug, Serialize)]
pub(super) struct FlattenedLocations {
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub clients: Vec<String>,
    pub locations: BTreeMap<String, Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub truncated: Option<Truncated>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub errors: BTreeMap<String, String>,
}

#[derive(Debug, Serialize)]
pub(super) struct Truncated {
    pub shown: usize,
    pub total: usize,
}
