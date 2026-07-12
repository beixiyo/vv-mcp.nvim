//! vv-mcp 命令行入口：读取运行配置并通过 stdio 启动 MCP Server

mod instance;
mod nvim;
mod output;
mod server;

use std::path::PathBuf;

use clap::{Parser, Subcommand};
use output::{OutputConfig, OutputFormat};
use rmcp::{ServiceExt, transport::stdio};
use serde_json::{Value, json};
use server::VvMcpServer;

#[derive(Debug, Parser)]
#[command(name = "vv-mcp", version, about)]
struct Args {
    #[command(subcommand)]
    command: Option<Command>,

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

#[derive(Debug, Subcommand)]
enum Command {
    /// 通过活动 Neovim 实例为一个文件应用可用的 LSP 修复
    Fix {
        /// 要修复的文件；相对路径基于当前目录解析
        path: PathBuf,

        /// 工作区根目录重叠时使用的精确 Neovim 实例 ID
        #[arg(long)]
        instance_id: Option<String>,

        /// 每次 Neovim 侧 LSP 请求的超时时间
        #[arg(long, default_value_t = 5000)]
        timeout_ms: u32,

        /// 仅修复指定的 1-based 行；省略时修复整个文件
        #[arg(long, value_parser = parse_line)]
        line: Option<u32>,
    },
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

fn parse_line(value: &str) -> Result<u32, String> {
    let value = value
        .parse::<u32>()
        .map_err(|_| "line must be a positive integer".to_owned())?;
    if value == 0 {
        return Err("line must be greater than zero".to_owned());
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

    if let Some(Command::Fix {
        path,
        instance_id,
        timeout_ms,
        line,
    }) = args.command
    {
        let path = absolute_path(path)?;
        let uri = path.to_string_lossy().into_owned();
        match server
            .fix_document(uri.clone(), instance_id, timeout_ms, line)
            .await
        {
            Ok(result) if result.get("error").is_none() => {
                println!("{}", fix_success(result));
            }
            Ok(result) if is_unavailable(&result) => {
                println!("{}", fix_skipped(&uri, error_code(&result)));
            }
            Ok(result) => anyhow::bail!("{}", result),
            Err(error) if error.starts_with("Neovim instance not found:") => {
                println!("{}", fix_skipped(&uri, "no_instance"));
            }
            Err(error) => anyhow::bail!(error),
        }
        return Ok(());
    }

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

fn absolute_path(path: PathBuf) -> anyhow::Result<PathBuf> {
    if path.is_absolute() {
        Ok(path)
    } else {
        Ok(std::env::current_dir()?.join(path))
    }
}

fn error_code(result: &Value) -> &str {
    result["error"]["code"].as_str().unwrap_or("unavailable")
}

fn is_unavailable(result: &Value) -> bool {
    matches!(
        error_code(result),
        "no_quickfixes" | "no_lsp" | "document_not_found" | "capability_unsupported"
    )
}

fn fix_skipped(path: &str, reason: &str) -> Value {
    json!({ "changed": false, "path": path, "reason": reason })
}

fn fix_success(result: Value) -> Value {
    json!({
        "changed": true,
        "saved": result["saved"],
        "filesChanged": result["filesChanged"],
        "editsCount": result["editsCount"],
        "clients": result["clients"],
        "titles": result["titles"],
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_zero_max_results() {
        assert!(parse_max_results("0").is_err());
        assert_eq!(parse_max_results("200").unwrap(), 200);
    }

    #[test]
    fn parses_fix_subcommand() {
        let args = Args::try_parse_from([
            "vv-mcp",
            "fix",
            "src/main.rs",
            "--timeout-ms",
            "7000",
            "--line",
            "12",
        ])
        .unwrap();
        assert!(matches!(
            args.command,
            Some(Command::Fix {
                path,
                timeout_ms: 7000,
                line: Some(12),
                ..
            }) if path == std::path::Path::new("src/main.rs")
        ));
    }

    #[test]
    fn rejects_zero_fix_line() {
        assert!(Args::try_parse_from(["vv-mcp", "fix", "src/main.rs", "--line", "0"]).is_err());
    }

    #[test]
    fn treats_expected_fix_absence_as_noop() {
        let result = json!({ "error": { "code": "no_quickfixes" } });
        assert!(is_unavailable(&result));
        assert_eq!(
            fix_skipped("/code/a.ts", error_code(&result))["changed"],
            false
        );
    }
}
