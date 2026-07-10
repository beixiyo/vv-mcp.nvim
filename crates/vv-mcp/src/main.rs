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
    /// Directory containing Neovim instance registry files.
    #[arg(long, env = "VV_MCP_REGISTRY")]
    registry: Option<PathBuf>,

    /// Print discovered instances as JSON and exit.
    #[arg(long)]
    list_instances: bool,

    /// LSP result format returned to MCP clients.
    #[arg(long, env = "VV_MCP_OUTPUT_FORMAT", value_enum, default_value = "json")]
    output_format: OutputFormat,

    /// Maximum number of LSP result items returned per request.
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
