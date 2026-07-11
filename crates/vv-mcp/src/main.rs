//! vv-mcp 命令行入口：读取运行配置并通过 stdio 启动 MCP Server

mod instance;
mod nvim;
mod output;
mod server;

use std::path::PathBuf;

use clap::Parser;
use output::{OutputConfig, OutputFormat};
use rmcp::{ServiceExt, transport::stdio};
use server::VvMcpServer;

#[derive(Debug, Parser)]
#[command(name = "vv-mcp", version, about)]
struct Args {
    /// Neovim 实例注册文件所在目录
    #[arg(long, env = "VV_MCP_REGISTRY")]
    registry: Option<PathBuf>,

    /// 以 JSON 输出已发现实例并退出
    #[arg(long)]
    list_instances: bool,

    /// 返回给 MCP 客户端的 LSP 结果格式
    #[arg(long, env = "VV_MCP_OUTPUT_FORMAT", value_enum, default_value = "json")]
    output_format: OutputFormat,

    /// 单次请求最多返回的 LSP 结果数量
    #[arg(
        long,
        env = "VV_MCP_MAX_RESULTS",
        default_value_t = 200,
        value_parser = parse_max_results
    )]
    max_results: usize,
}

fn parse_max_results(value: &str) -> Result<usize, String> {
    let value = value
        .parse::<usize>()
        .map_err(|_| "max results must be a positive integer".to_owned())?;
    if value == 0 {
        return Err("max results must be greater than zero".to_owned());
    }
    Ok(value)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    let server = VvMcpServer::new(
        args.registry,
        OutputConfig {
            format: args.output_format,
            max_results: args.max_results,
        },
    )?;

    if args.list_instances {
        println!(
            "{}",
            serde_json::to_string_pretty(&server.instances().await?)?
        );
        return Ok(());
    }

    let service = server.serve(stdio()).await?;
    service.waiting().await?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_zero_max_results() {
        assert!(parse_max_results("0").is_err());
        assert_eq!(parse_max_results("200").unwrap(), 200);
    }
}
