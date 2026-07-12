//! vv-mcp 命令行入口：读取运行配置并通过 stdio 启动 MCP Server

mod instance;
mod nvim;
mod output;
mod server;

use std::{
    collections::BTreeSet,
    io::IsTerminal,
    path::{Path, PathBuf},
};

use clap::{CommandFactory, Parser, Subcommand};
use ignore::WalkBuilder;
use output::{OutputConfig, OutputFormat};
use rmcp::{ServiceExt, transport::stdio};
use serde_json::{Value, json};
use server::{EditorParams, LspParams, VvMcpServer};

#[derive(Debug, Parser)]
#[command(name = "vv-mcp", version, about)]
struct Args {
    #[command(subcommand)]
    command: Option<Command>,

    /// Directory containing Neovim instance registry files
    #[arg(long, env = "VV_MCP_REGISTRY", global = true)]
    registry: Option<PathBuf>,

    /// List discovered instances as JSON and exit
    #[arg(long)]
    list_instances: bool,

    /// Result output format; defaults to markdown for commands and json for MCP server
    #[arg(long, env = "VV_MCP_OUTPUT_FORMAT", value_enum, global = true)]
    output_format: Option<OutputFormat>,

    /// Exact Neovim instance ID when workspace roots overlap; omit for automatic routing by path
    #[arg(long, global = true)]
    instance_id: Option<String>,

    /// Request timeout in milliseconds; defaults to 5000ms for fix, other ops use Neovim defaults
    #[arg(long, value_parser = parse_timeout, global = true)]
    timeout_ms: Option<u32>,

    /// Maximum number of results per request
    #[arg(
        long,
        env = "VV_MCP_MAX_RESULTS",
        default_value_t = 200,
        value_parser = parse_max_results,
        global = true
    )]
    max_results: usize,
}

#[derive(Debug, Subcommand)]
// LspParams 字段多、体积大，但 clap 的 #[command(flatten)] 无法作用于 Box<T>，这里只能内嵌
#[allow(clippy::large_enum_variant)]
enum Command {
    /// Apply available LSP fixes to a file through the active Neovim instance
    Fix {
        /// File to fix; relative paths are resolved from current directory
        path: PathBuf,

        /// Fix only the specified 1-based line; omit to fix the entire file
        #[arg(long, value_parser = parse_line, conflicts_with = "all")]
        line: Option<u32>,

        /// Serially fix all files in directory not excluded by ignore rules
        #[arg(long)]
        all: bool,
    },

    /// Execute an LSP operation directly; parameters are shared with the MCP `lsp` tool
    Lsp {
        #[command(flatten)]
        params: LspParams,

        /// Confirm execution of disk-writing operations (`fix_document`, `code_action_apply`, `rename_apply`)
        #[arg(long)]
        yes: bool,
    },

    /// Read live editor state from Neovim; read-only, parameters shared with the MCP `editor` tool
    Editor {
        #[command(flatten)]
        params: EditorParams,
    },
}

/// 批量修复要等语言服务器冷启动，默认给得比交互式查询宽松
const DEFAULT_FIX_TIMEOUT_MS: u32 = 5000;

fn parse_timeout(value: &str) -> Result<u32, String> {
    let value = value
        .parse::<u32>()
        .map_err(|_| "timeout must be a positive integer".to_owned())?;
    if value == 0 {
        return Err("timeout must be greater than zero".to_owned());
    }
    Ok(value)
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
            format: resolve_format(args.output_format, args.command.is_some()),
            max_results: args.max_results,
        },
    )?;

    // --instance-id 与 --timeout-ms 是全局选项：三个子命令都要路由到实例、都要发 RPC，
    // 所以它们在每个子命令下都真实生效，而不是「用不上就忽略」
    let instance_id = args.instance_id;
    let timeout_ms = args.timeout_ms;

    match args.command {
        Some(Command::Lsp { mut params, yes }) => {
            params.set_routing(instance_id, timeout_ms);
            params.set_uri(cli_uri(params.uri())?);
            return run_lsp_command(&server, params, yes).await;
        }
        Some(Command::Editor { mut params }) => {
            params.set_routing(instance_id, timeout_ms);
            if let Some(uri) = params.uri() {
                params.set_uri(cli_uri(uri)?);
            }
            return run_editor_command(&server, params).await;
        }
        Some(Command::Fix { path, line, all }) => {
            return run_fix_command(
                &server,
                path,
                instance_id,
                timeout_ms.unwrap_or(DEFAULT_FIX_TIMEOUT_MS),
                line,
                all,
            )
            .await;
        }
        None => {}
    }

    if args.list_instances {
        println!(
            "{}",
            serde_json::to_string_pretty(&server.instances().await?)?
        );
        return Ok(());
    }

    // 无参数即 MCP server 模式（客户端就是这么启动它的），会一直在 stdin 上等 JSON-RPC。
    // 但人在终端里直接敲 `vv-mcp` 时 stdin 是 TTY，那种「静默卡住」毫无意义，给出帮助更有用
    if std::io::stdin().is_terminal() {
        Args::command().print_help()?;
        println!(
            "\n\nWith no subcommand and piped stdin, vv-mcp serves the MCP protocol over stdio."
        );
        return Ok(());
    }

    let service = server.serve(stdio()).await?;
    service.waiting().await?;

    Ok(())
}

/// 直接执行一次 LSP 操作：写盘操作要求显式 --yes，结果按统一输出格式渲染
async fn run_lsp_command(server: &VvMcpServer, params: LspParams, yes: bool) -> anyhow::Result<()> {
    if params.writes_to_disk() && !yes {
        anyhow::bail!(
            "{} writes to disk; pass --yes to confirm",
            params.operation_name()
        );
    }

    let raw = request_result(server.run_lsp(&params).await);
    let failed = raw.get("error").is_some();
    emit(server.format_lsp(params.operation_name(), raw), failed)
}

/// 读取一次编辑器实时状态；只读，无需确认
async fn run_editor_command(server: &VvMcpServer, params: EditorParams) -> anyhow::Result<()> {
    let raw = request_result(server.run_editor(&params).await);
    let failed = raw.get("error").is_some();
    emit(server.format_editor(params.operation_name(), raw), failed)
}

/// 命令行是给人看的，默认 markdown；MCP server 面向程序，默认 json
/// 显式 `--output-format` 或 `VV_MCP_OUTPUT_FORMAT` 始终优先
fn resolve_format(explicit: Option<OutputFormat>, is_command: bool) -> OutputFormat {
    explicit.unwrap_or(if is_command {
        OutputFormat::Markdown
    } else {
        OutputFormat::Json
    })
}

/// 命令行上的路径按 cwd 解析成绝对路径，和 `fix` 子命令保持一致；
/// `file://` URI 原样透传，交给 Neovim 侧规范化
fn cli_uri(uri: &str) -> anyhow::Result<String> {
    if uri.starts_with("file://") {
        return Ok(uri.to_owned());
    }
    Ok(absolute_path(PathBuf::from(uri))?
        .to_string_lossy()
        .into_owned())
}

/// 传输层失败也折叠成统一的错误结果，交给同一套格式化渲染
fn request_result(result: Result<Value, String>) -> Value {
    result
        .unwrap_or_else(|error| json!({ "error": { "code": "request_failed", "message": error } }))
}

/// 打印结果；带 error 的结果以退出码 1 结束，便于 hook 与脚本判断成败
fn emit(rendered: String, failed: bool) -> anyhow::Result<()> {
    println!("{rendered}");
    if failed {
        std::process::exit(1);
    }
    Ok(())
}

async fn run_fix_command(
    server: &VvMcpServer,
    path: PathBuf,
    instance_id: Option<String>,
    timeout_ms: u32,
    line: Option<u32>,
    all: bool,
) -> anyhow::Result<()> {
    let path = absolute_path(path)?;
    if path.is_dir() {
        if !all {
            anyhow::bail!("directory paths require --all");
        }
        let result = fix_directory(server, &path, instance_id, timeout_ms).await?;
        println!("{result}");
        return Ok(());
    }
    if all {
        anyhow::bail!("--all requires a directory path");
    }
    if !path.is_file() {
        anyhow::bail!(
            "path does not exist or is not a regular file: {}",
            path.display()
        );
    }

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
    Ok(())
}

async fn fix_directory(
    server: &VvMcpServer,
    root: &Path,
    instance_id: Option<String>,
    timeout_ms: u32,
) -> anyhow::Result<Value> {
    let root_uri = root.to_string_lossy().into_owned();
    let instance = server
        .resolve_active_instance(&root_uri, instance_id.as_deref())
        .await
        .map_err(anyhow::Error::msg)?;
    let files = workspace_files(root)?;
    let mut changed_files = 0_u64;
    let mut skipped_files = 0_u64;
    let mut edits_count = 0_u64;
    let mut clients = BTreeSet::new();
    let mut pending_clients = BTreeSet::new();
    let mut failures = Vec::new();

    for path in &files {
        let uri = path.to_string_lossy().into_owned();
        match server
            .fix_document_on_instance(&instance, uri.clone(), timeout_ms)
            .await
        {
            Ok(result) if result.get("error").is_none() => {
                changed_files += 1;
                edits_count += result["editsCount"].as_u64().unwrap_or(0);
                collect_names(&result["clients"], &mut clients);
                collect_names(&result["pendingClients"], &mut pending_clients);
            }
            Ok(result) if is_unavailable(&result) => skipped_files += 1,
            Ok(result) => failures.push(json!({
                "path": uri,
                "error": result.get("error").cloned().unwrap_or(result),
            })),
            Err(error) => anyhow::bail!(
                "active Neovim instance request failed for {uri} ({}): {error}",
                instance.instance_id
            ),
        }
    }

    Ok(json!({
        "changed": changed_files > 0,
        "root": root_uri,
        "instanceId": instance.instance_id,
        "scannedFiles": files.len(),
        "changedFiles": changed_files,
        "skippedFiles": skipped_files,
        "failedFiles": failures.len(),
        "editsCount": edits_count,
        "clients": clients,
        "pendingClients": pending_clients,
        "failures": failures,
    }))
}

/// 汇总一次结果里的客户端名，缺失或类型不符时视为空
fn collect_names(value: &Value, into: &mut BTreeSet<String>) {
    for name in value.as_array().into_iter().flatten() {
        if let Some(name) = name.as_str() {
            into.insert(name.to_owned());
        }
    }
}

fn workspace_files(root: &Path) -> anyhow::Result<Vec<PathBuf>> {
    let mut files = Vec::new();
    let mut builder = WalkBuilder::new(root);
    builder
        .standard_filters(true)
        .follow_links(false)
        .sort_by_file_path(|left, right| left.cmp(right));
    for entry in builder.build() {
        let entry = entry?;
        if entry.file_type().is_some_and(|kind| kind.is_file()) {
            files.push(entry.into_path());
        }
    }
    Ok(files)
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
    let mut success = json!({
        "changed": true,
        "saved": result["saved"],
        "filesChanged": result["filesChanged"],
        "editsCount": result["editsCount"],
        "clients": result["clients"],
        "titles": result["titles"],
    });
    // 仍在握手的客户端意味着它的修复项本次没拿到，不能让这点在「成功」里消失
    if let Some(pending) = result.get("pendingClients") {
        success["pendingClients"] = pending.clone();
    }
    success
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        time::{SystemTime, UNIX_EPOCH},
    };

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
        // --timeout-ms 是全局选项，写在子命令之后同样生效
        assert_eq!(args.timeout_ms, Some(7000));
        assert!(matches!(
            args.command,
            Some(Command::Fix {
                path,
                line: Some(12),
                all: false,
            }) if path == std::path::Path::new("src/main.rs")
        ));
    }

    #[test]
    fn routes_global_flags_into_every_subcommand() {
        // 全局选项在子命令前后都能写，且对三个子命令都真实生效
        let before = Args::try_parse_from([
            "vv-mcp",
            "--instance-id",
            "proj:1",
            "--timeout-ms",
            "9000",
            "lsp",
            "--operation",
            "hover",
            "--uri",
            "/a.ts",
        ])
        .unwrap();
        let after = Args::try_parse_from([
            "vv-mcp",
            "lsp",
            "--operation",
            "hover",
            "--uri",
            "/a.ts",
            "--instance-id",
            "proj:1",
            "--timeout-ms",
            "9000",
        ])
        .unwrap();
        assert_eq!(before.instance_id.as_deref(), Some("proj:1"));
        assert_eq!(before.instance_id, after.instance_id);
        assert_eq!(before.timeout_ms, after.timeout_ms);

        // 注入之后必须出现在线上负载里，而不是被悄悄丢掉
        let Some(Command::Lsp { mut params, .. }) = after.command else {
            panic!("expected the lsp subcommand");
        };
        params.set_routing(after.instance_id, after.timeout_ms);
        let wire = serde_json::to_value(&params).unwrap();
        assert_eq!(wire["instanceId"], "proj:1");
        assert_eq!(wire["timeoutMs"], 9000);

        // editor 同样接受这两个全局选项：它也要路由到实例、也要发 RPC
        let editor = Args::try_parse_from([
            "vv-mcp",
            "editor",
            "--operation",
            "list_buffers",
            "--instance-id",
            "proj:1",
            "--timeout-ms",
            "9000",
        ])
        .unwrap();
        let Some(Command::Editor { mut params }) = editor.command else {
            panic!("expected the editor subcommand");
        };
        params.set_routing(editor.instance_id, editor.timeout_ms);
        let wire = serde_json::to_value(&params).unwrap();
        assert_eq!(wire["instanceId"], "proj:1");
        assert_eq!(wire["timeoutMs"], 9000);
    }

    #[test]
    fn resolves_relative_cli_paths_like_the_fix_subcommand() {
        let cwd = std::env::current_dir().unwrap();
        assert_eq!(
            cli_uri("src/main.rs").unwrap(),
            cwd.join("src/main.rs").to_string_lossy()
        );
        // 绝对路径与 file:// URI 原样透传
        assert_eq!(cli_uri("/work/a.ts").unwrap(), "/work/a.ts");
        assert_eq!(cli_uri("file:///work/a.ts").unwrap(), "file:///work/a.ts");
    }

    #[test]
    fn rejects_zero_timeout() {
        assert!(
            Args::try_parse_from(["vv-mcp", "fix", "src/main.rs", "--timeout-ms", "0"]).is_err()
        );
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

    #[test]
    fn parses_lsp_subcommand_from_shared_params() {
        let args = Args::try_parse_from([
            "vv-mcp",
            "lsp",
            "--operation",
            "references",
            "--uri",
            "/work/a.ts",
            "--line",
            "42",
            "--character",
            "17",
            "--include-external",
            "false",
        ])
        .unwrap();

        let Some(Command::Lsp { params, yes }) = args.command else {
            panic!("expected the lsp subcommand");
        };
        assert_eq!(params.operation_name(), "references");
        assert!(!params.writes_to_disk());
        assert!(!yes);
        // 命令行入参必须序列化成与 MCP 工具完全一致的线上负载
        let wire = serde_json::to_value(&params).unwrap();
        assert_eq!(wire["operation"], "references");
        assert_eq!(wire["uri"], "/work/a.ts");
        assert_eq!(wire["line"], 42);
        assert_eq!(wire["includeExternal"], false);
        assert!(wire.get("cleanupTemporary").is_none());
    }

    #[test]
    fn flags_disk_writing_operations_for_confirmation() {
        let writes = |operation: &str| {
            let args =
                Args::try_parse_from(["vv-mcp", "lsp", "--operation", operation, "--uri", "/a.ts"])
                    .unwrap();
            match args.command {
                Some(Command::Lsp { params, .. }) => params.writes_to_disk(),
                _ => panic!("expected the lsp subcommand"),
            }
        };

        assert!(writes("fix_document"));
        assert!(writes("code_action_apply"));
        assert!(writes("rename_apply"));
        assert!(!writes("hover"));
        assert!(!writes("fix_document_preview"));
        assert!(!writes("rename_preview"));
    }

    #[test]
    fn rejects_unknown_lsp_operation() {
        assert!(
            Args::try_parse_from(["vv-mcp", "lsp", "--operation", "nope", "--uri", "/a.ts"])
                .is_err()
        );
        // 内部字段不得出现在命令行
        assert!(
            Args::try_parse_from([
                "vv-mcp",
                "lsp",
                "--operation",
                "hover",
                "--uri",
                "/a.ts",
                "--cleanup-temporary",
                "true",
            ])
            .is_err()
        );
    }

    #[test]
    fn defaults_to_markdown_for_commands_and_json_for_the_mcp_server() {
        assert_eq!(resolve_format(None, true), OutputFormat::Markdown);
        assert_eq!(resolve_format(None, false), OutputFormat::Json);
        // 显式指定始终优先，两种模式都不例外
        assert_eq!(
            resolve_format(Some(OutputFormat::Json), true),
            OutputFormat::Json
        );
        assert_eq!(
            resolve_format(Some(OutputFormat::Markdown), false),
            OutputFormat::Markdown
        );
    }

    #[test]
    fn parses_editor_subcommand_from_shared_params() {
        let args = Args::try_parse_from([
            "vv-mcp",
            "editor",
            "--operation",
            "read_buffer",
            "--uri",
            "/work/a.ts",
            "--start-line",
            "10",
            "--max-lines",
            "50",
        ])
        .unwrap();

        let Some(Command::Editor { params }) = args.command else {
            panic!("expected the editor subcommand");
        };
        assert_eq!(params.operation_name(), "read_buffer");
        let wire = serde_json::to_value(&params).unwrap();
        assert_eq!(wire["operation"], "read_buffer");
        assert_eq!(wire["startLine"], 10);
        assert_eq!(wire["maxLines"], 50);
        assert!(wire.get("endLine").is_none());
    }

    #[test]
    fn requires_all_for_directories() {
        let args = Args::try_parse_from(["vv-mcp", "fix", ".", "--all"]).unwrap();
        assert!(matches!(args.command, Some(Command::Fix { all: true, .. })));
        assert!(Args::try_parse_from(["vv-mcp", "fix", ".", "--all", "--line", "1"]).is_err());
    }

    #[test]
    fn walks_repository_files_in_order_and_respects_gitignore() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("vv-mcp-fix-all-{nonce}"));
        fs::create_dir_all(root.join(".git")).unwrap();
        fs::create_dir_all(root.join("src")).unwrap();
        fs::create_dir_all(root.join("ignored")).unwrap();
        fs::write(root.join(".gitignore"), "ignored/\n").unwrap();
        fs::write(root.join("src/b.ts"), "export const b = 1\n").unwrap();
        fs::write(root.join("src/a.ts"), "export const a = 1\n").unwrap();
        fs::write(root.join("ignored/c.ts"), "export const c = 1\n").unwrap();

        let files = workspace_files(&root).unwrap();
        assert_eq!(files, vec![root.join("src/a.ts"), root.join("src/b.ts")]);
        fs::remove_dir_all(root).unwrap();
    }
}
