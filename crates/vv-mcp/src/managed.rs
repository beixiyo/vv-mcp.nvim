//! 按项目根复用无界面 Neovim，并在闲置后回收，供没有交互式实例的 LSP 请求使用

use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
    process::Stdio,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};

use ignore::WalkBuilder;
use tokio::{
    process::{Child, Command},
    sync::Mutex,
    time::Instant,
};

use crate::{
    instance::{Instance, Registry},
    nvim::NvimClient,
    uri,
};

const DEFAULT_IDLE_TIMEOUT: Duration = Duration::from_secs(5 * 60);
const DEFAULT_HANDOFF_DELAY: Duration = Duration::from_secs(15);
const DEFAULT_WATCH_INTERVAL: Duration = Duration::from_secs(1);
const DEFAULT_READY_TIMEOUT: Duration = Duration::from_secs(15);
const ROOT_MARKERS: &[&str] = &[
    "package.json",
    "pnpm-workspace.yaml",
    "pnpm-lock.yaml",
    "yarn.lock",
    "package-lock.json",
    "bun.lock",
    "bun.lockb",
    "deno.json",
    "deno.jsonc",
    "Cargo.toml",
    "go.mod",
    "pyproject.toml",
    "uv.lock",
    "poetry.lock",
    "Pipfile",
    "requirements.txt",
    "pom.xml",
    "build.gradle",
    "build.gradle.kts",
    "settings.gradle",
    "settings.gradle.kts",
    "composer.json",
    "Gemfile",
    "mix.exs",
    "Package.swift",
    "CMakeLists.txt",
];

static NEXT_SOCKET_ID: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug)]
pub struct ManagedPool {
    registry: Registry,
    processes: Arc<Mutex<HashMap<PathBuf, ManagedProcess>>>,
    idle_timeout: Duration,
    handoff_delay: Duration,
    watch_interval: Duration,
    ready_timeout: Duration,
}

#[derive(Debug)]
struct ManagedProcess {
    child: Child,
    pid: u32,
    socket: String,
}

impl ManagedPool {
    pub fn new(registry: Registry) -> Self {
        Self {
            registry,
            processes: Arc::new(Mutex::new(HashMap::new())),
            idle_timeout: managed_duration("VV_MCP_MANAGED_IDLE_TIMEOUT_MS", DEFAULT_IDLE_TIMEOUT),
            handoff_delay: managed_duration(
                "VV_MCP_MANAGED_HANDOFF_DELAY_MS",
                DEFAULT_HANDOFF_DELAY,
            ),
            watch_interval: managed_duration(
                "VV_MCP_MANAGED_WATCH_INTERVAL_MS",
                DEFAULT_WATCH_INTERVAL,
            ),
            ready_timeout: managed_duration(
                "VV_MCP_MANAGED_READY_TIMEOUT_MS",
                DEFAULT_READY_TIMEOUT,
            ),
        }
    }

    pub fn set_idle_timeout(&mut self, timeout: Duration) {
        self.idle_timeout = timeout;
    }

    pub fn idle_timeout_ms(&self) -> u64 {
        self.idle_timeout.as_millis() as u64
    }

    pub async fn ensure(&self, uri: &str) -> Result<Instance, String> {
        let deadline = Instant::now() + self.ready_timeout;
        let file = native_path(uri)?;
        let root = project_root(&file)?;
        let (pid, started) = {
            let mut processes = self.processes.lock().await;
            if let Some(process) = processes.get_mut(&root) {
                if process.child.try_wait().ok().flatten().is_none() {
                    (process.pid, false)
                } else {
                    processes.remove(&root);
                    let process = spawn(&root, &file, self)?;
                    let pid = process.pid;
                    processes.insert(root.clone(), process);
                    (pid, true)
                }
            } else {
                let process = spawn(&root, &file, self)?;
                let pid = process.pid;
                processes.insert(root.clone(), process);
                (pid, true)
            }
        };

        match wait_for_instance(
            &self.registry,
            pid,
            deadline.saturating_duration_since(Instant::now()),
        )
        .await
        {
            Ok(instance) => {
                if started {
                    // 注册成功后，自主管理模块已有启动超时兜底；取消 broker 不应反复杀掉冷启动
                    let process = self.processes.lock().await.remove(&root);
                    let retained =
                        retain_instance(&instance, &file, self.idle_timeout_ms(), deadline).await;
                    if let Err(error) = retained {
                        if let Some(mut process) = process {
                            stop(&mut process).await;
                        }
                        return Err(error);
                    }
                }
                Ok(instance)
            }
            Err(error) => {
                self.remove_and_stop(&root, pid).await;
                Err(error)
            }
        }
    }

    async fn remove_and_stop(&self, root: &Path, pid: u32) {
        let process = {
            let mut processes = self.processes.lock().await;
            let matches = processes
                .get(root)
                .is_some_and(|process| process.pid == pid);
            matches.then(|| processes.remove(root)).flatten()
        };
        if let Some(mut process) = process {
            stop(&mut process).await;
        }
    }

    pub async fn shutdown(&self) {
        let processes = {
            let mut processes = self.processes.lock().await;
            processes
                .drain()
                .map(|(_, process)| process)
                .collect::<Vec<_>>()
        };
        for mut process in processes {
            stop(&mut process).await;
        }
    }

    pub fn ready_timeout(&self) -> Duration {
        self.ready_timeout
    }
}

impl Drop for ManagedPool {
    fn drop(&mut self) {
        if Arc::strong_count(&self.processes) != 1 {
            return;
        }
        let Ok(mut processes) = self.processes.try_lock() else {
            return;
        };
        for process in processes.values_mut() {
            let _ = process.child.start_kill();
        }
    }
}

fn managed_duration(name: &str, default: Duration) -> Duration {
    let milliseconds = std::env::var(name)
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(default.as_millis() as u64);
    Duration::from_millis(milliseconds)
}

fn native_path(uri: &str) -> Result<PathBuf, String> {
    let path = uri::native_path(uri)?;
    if !path.is_file() && !path.is_dir() {
        return Err(format!(
            "path does not exist or is not a regular file or directory: {}",
            path.display()
        ));
    }
    fs::canonicalize(path).map_err(|error| error.to_string())
}

fn project_root(file: &Path) -> Result<PathBuf, String> {
    let start = if file.is_dir() {
        file
    } else {
        file.parent()
            .ok_or_else(|| format!("file has no parent: {}", file.display()))?
    };
    for directory in start.ancestors() {
        if directory.join(".git").exists() {
            return Ok(directory.to_path_buf());
        }
    }
    for directory in start.ancestors() {
        if ROOT_MARKERS
            .iter()
            .any(|marker| directory.join(marker).exists())
        {
            return Ok(directory.to_path_buf());
        }
    }
    Ok(start.to_path_buf())
}

// 冷启动只取有限的、遵守 ignore 的候选文件；语言与启动配置由 Neovim 决定
const MAX_WORKSPACE_BOOTSTRAP_FILES: usize = 4096;

fn workspace_candidates(
    directory: &Path,
    deadline: Instant,
    mut cancelled: impl FnMut() -> bool,
) -> Result<Vec<String>, String> {
    let mut check = || {
        if cancelled() || Instant::now() >= deadline {
            Err("Workspace discovery canceled or timed out".to_string())
        } else {
            Ok(())
        }
    };
    check()?;

    let mut files = Vec::new();
    for entry in WalkBuilder::new(directory)
        .sort_by_file_path(|a, b| a.cmp(b))
        .build()
    {
        // 包括目录：文件数量上限无法约束大量空目录的遍历
        check()?;
        let entry = entry.map_err(|error| error.to_string())?;
        if entry.file_type().is_some_and(|kind| kind.is_file()) {
            files.push(entry.path().to_string_lossy().into_owned());
            if files.len() >= MAX_WORKSPACE_BOOTSTRAP_FILES {
                break;
            }
        }
    }
    Ok(files)
}

async fn retain_instance(
    instance: &Instance,
    target: &Path,
    idle_timeout_ms: u64,
    deadline: Instant,
) -> Result<(), String> {
    let preparing = target.is_dir();
    let files = if preparing {
        let directory = target.to_path_buf();
        // 调用 future 被取消或超时时 sender 随作用域释放，worker 在下一项停止
        let (_cancel, mut cancelled) = tokio::sync::oneshot::channel::<()>();
        tokio::time::timeout_at(
            deadline,
            tokio::task::spawn_blocking(move || {
                workspace_candidates(&directory, deadline, || {
                    !matches!(
                        cancelled.try_recv(),
                        Err(tokio::sync::oneshot::error::TryRecvError::Empty)
                    )
                })
            }),
        )
        .await
        .map_err(|_| "Workspace discovery timed out".to_string())?
        .map_err(|error| error.to_string())??
    } else {
        Vec::new()
    };
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err("Managed Neovim startup timed out".into());
    }
    let mut client = NvimClient::connect(&instance.socket)
        .await
        .map_err(|error| error.to_string())?;
    let _: bool = client
        .exec_lua_with_timeout(
            "return require('vv-mcp.managed').start(...)",
            vec![
                serde_json::json!(idle_timeout_ms),
                serde_json::json!(preparing),
                serde_json::json!(files),
                serde_json::json!(remaining.as_millis() as u64),
            ],
            remaining,
        )
        .await
        .map_err(|error| error.to_string())?;
    Ok(())
}

fn spawn(root: &Path, file: &Path, pool: &ManagedPool) -> Result<ManagedProcess, String> {
    let socket = std::env::temp_dir().join(format!(
        "vv-mcp-{}-{}.sock",
        std::process::id(),
        NEXT_SOCKET_ID.fetch_add(1, Ordering::Relaxed),
    ));

    let _ = fs::remove_file(&socket);
    let mut command = Command::new("nvim");
    command.arg("--headless").arg("--listen").arg(&socket);
    // 目录仅作为路由和扫描范围，不把它交给 netrw 或其他目录浏览插件
    if file.is_file() {
        command.arg(file);
    }

    // 不继承短命 broker 的管道和进程组，避免等待 EOF 或取消时误杀保活实例
    #[cfg(unix)]
    command.process_group(0);
    let child = command
        .current_dir(root)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .env("VV_MCP_MANAGED", "1")
        .env("VV_MCP_REGISTRY", pool.registry.dir())
        .env(
            "VV_MCP_MANAGED_IDLE_TIMEOUT_MS",
            pool.idle_timeout.as_millis().to_string(),
        )
        .env(
            "VV_MCP_MANAGED_HANDOFF_DELAY_MS",
            pool.handoff_delay.as_millis().to_string(),
        )
        .env(
            "VV_MCP_MANAGED_WATCH_INTERVAL_MS",
            pool.watch_interval.as_millis().to_string(),
        )
        .env(
            "VV_MCP_MANAGED_READY_TIMEOUT_MS",
            pool.ready_timeout.as_millis().to_string(),
        )
        .kill_on_drop(false)
        .spawn()
        .map_err(|error| format!("failed to start managed Neovim: {error}"))?;
    let pid = child
        .id()
        .ok_or_else(|| "managed Neovim has no PID".to_owned())?;
    Ok(ManagedProcess {
        child,
        pid,
        socket: socket.to_string_lossy().into_owned(),
    })
}

async fn stop(process: &mut ManagedProcess) {
    if let Ok(mut client) = NvimClient::connect(&process.socket).await {
        let _: Result<bool, _> = client
            .exec_lua_with_timeout(
                "vim.schedule(function() vim.cmd('silent! qa!') end); return true",
                Vec::<String>::new(),
                Duration::from_secs(1),
            )
            .await;
    }
    if tokio::time::timeout(Duration::from_secs(2), process.child.wait())
        .await
        .is_err()
    {
        let _ = process.child.kill().await;
    }
    let _ = fs::remove_file(&process.socket);
}

async fn wait_for_instance(
    registry: &Registry,
    pid: u32,
    ready_timeout: Duration,
) -> Result<Instance, String> {
    let deadline = Instant::now() + ready_timeout;
    loop {
        let instances = registry.list().await.map_err(|error| error.to_string())?;
        if let Some(instance) = instances
            .instances
            .into_iter()
            .find(|instance| instance.pid == pid)
        {
            return Ok(instance);
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "managed Neovim did not register within {} ms",
                ready_timeout.as_millis()
            ));
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn directory_targets_resolve_their_own_project_and_ignore_dependency_files() {
        let root =
            std::env::temp_dir().join(format!("vv-mcp-directory-test-{}", std::process::id()));
        fs::create_dir_all(root.join(".git")).unwrap();
        fs::create_dir_all(root.join("src")).unwrap();
        fs::create_dir_all(root.join("node_modules/dependency")).unwrap();
        fs::write(root.join(".gitignore"), "node_modules/\n").unwrap();
        fs::write(root.join("src/main.ts"), "export const value = 1\n").unwrap();
        fs::write(root.join("node_modules/dependency/index.ts"), "ignored\n").unwrap();
        let canonical = fs::canonicalize(&root).unwrap();
        assert_eq!(native_path(root.to_str().unwrap()).unwrap(), canonical);
        assert_eq!(project_root(&root).unwrap(), root);
        assert_eq!(project_root(&root.join("src")).unwrap(), root);
        assert_eq!(
            workspace_candidates(&root, Instant::now() + Duration::from_secs(5), || false).unwrap(),
            vec![root.join("src/main.ts").to_string_lossy().into_owned()]
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn workspace_discovery_honors_deadline_and_cancellation_for_empty_directories() {
        let root = std::env::temp_dir().join(format!("vv-mcp-scan-cancel-{}", std::process::id()));
        for index in 0..8 {
            fs::create_dir_all(root.join(index.to_string())).unwrap();
        }
        let expired = workspace_candidates(&root, Instant::now(), || false);
        let mut visited = 0;
        let cancelled =
            workspace_candidates(&root, Instant::now() + Duration::from_secs(5), || {
                visited += 1;
                visited > 2
            });
        fs::remove_dir_all(root).unwrap();
        assert!(expired.is_err(), "过期预算不能继续发现文件");
        assert!(
            cancelled.is_err(),
            "遍历空目录也必须响应取消，而不是返回空项目"
        );
    }

    #[test]
    fn prefers_git_root_over_nested_package_manifest() {
        let root = std::env::temp_dir().join(format!("vv-mcp-root-test-{}", std::process::id()));
        let file = root.join("apps/web/src/main.ts");
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::create_dir(root.join(".git")).unwrap();
        fs::write(root.join("apps/web/package.json"), "{}").unwrap();
        fs::write(&file, "export {}\n").unwrap();
        assert_eq!(project_root(&file).unwrap(), root);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn supports_git_worktree_file_and_ignores_gitignore_as_a_root_marker() {
        let root =
            std::env::temp_dir().join(format!("vv-mcp-worktree-test-{}", std::process::id()));
        let worktree = root.join("worktree");
        let source = worktree.join("src/main.rs");
        fs::create_dir_all(source.parent().unwrap()).unwrap();
        fs::write(worktree.join(".git"), "gitdir: ../git/worktrees/test\n").unwrap();
        fs::write(&source, "fn main() {}\n").unwrap();
        assert_eq!(project_root(&source).unwrap(), worktree);

        let orphan = root.join("orphan/src/main.rs");
        fs::create_dir_all(orphan.parent().unwrap()).unwrap();
        fs::write(root.join("orphan/.gitignore"), "target/\n").unwrap();
        fs::write(&orphan, "fn main() {}\n").unwrap();
        assert_eq!(project_root(&orphan).unwrap(), orphan.parent().unwrap());
        fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn stop_reaps_child_and_removes_socket() {
        let socket = std::env::temp_dir().join(format!(
            "vv-mcp-stop-test-{}-{}.sock",
            std::process::id(),
            NEXT_SOCKET_ID.fetch_add(1, Ordering::Relaxed)
        ));
        let child = Command::new("nvim")
            .args(["-u", "NONE", "-i", "NONE"])
            .arg("--headless")
            .arg("--listen")
            .arg(&socket)
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let pid = child.id().unwrap();
        let mut process = ManagedProcess {
            child,
            pid,
            socket: socket.to_string_lossy().into_owned(),
        };
        for _ in 0..100 {
            if socket.exists() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(socket.exists(), "Neovim did not create its listen socket");

        stop(&mut process).await;

        assert!(process.child.try_wait().unwrap().is_some());
        assert!(!socket.exists());
    }

    #[tokio::test]
    async fn registration_failure_removes_managed_process_from_pool() {
        let fixture = std::env::temp_dir().join(format!(
            "vv-mcp-registration-failure-{}",
            std::process::id()
        ));
        let file = fixture.join("main.unknown");
        let invalid_registry = fixture.join("registry-is-a-file");
        fs::create_dir_all(&fixture).unwrap();
        fs::write(&file, "plain text\n").unwrap();
        fs::write(&invalid_registry, "not a directory\n").unwrap();

        let registry = Registry::new(Some(invalid_registry)).unwrap();
        let pool = ManagedPool {
            registry,
            processes: Arc::new(Mutex::new(HashMap::new())),
            idle_timeout: Duration::from_secs(1),
            handoff_delay: Duration::from_secs(1),
            watch_interval: Duration::from_millis(10),
            ready_timeout: Duration::from_millis(50),
        };
        assert!(pool.ensure(file.to_str().unwrap()).await.is_err());
        assert!(pool.processes.lock().await.is_empty());

        fs::remove_dir_all(fixture).unwrap();
    }
}
