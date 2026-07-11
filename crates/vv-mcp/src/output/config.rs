//! 输出格式与最大结果数量配置

use clap::ValueEnum;
use serde::Serialize;

#[derive(Clone, Debug)]
pub struct OutputConfig {
    pub format: OutputFormat,
    pub max_results: usize,
}

impl Default for OutputConfig {
    fn default() -> Self {
        Self {
            format: OutputFormat::Json,
            max_results: 200,
        }
    }
}

#[derive(Clone, Copy, Debug, Serialize, ValueEnum)]
#[serde(rename_all = "lowercase")]
pub enum OutputFormat {
    Json,
    Markdown,
}
