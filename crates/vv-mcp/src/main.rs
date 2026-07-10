mod instance;
mod nvim;
mod server;

use std::path::PathBuf;

use clap::Parser;
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
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    let server = VvMcpServer::new(args.registry)?;

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
