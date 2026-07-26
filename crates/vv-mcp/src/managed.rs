//! 按项目根复用无界面 Neovim，并在闲置后回收，供没有交互式实例的 LSP 请求使用

use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};

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

const DEFAULT_IDLE_TIMEOUT: Duration = Duration::from_secs(15 * 60);
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
    last_used: Instant,
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

    pub async fn touch(&self, instance: &Instance) {
        if instance.kind != "managed" {
            return;
        }
        let mut processes = self.processes.lock().await;
        if let Some(process) = processes
            .values_mut()
            .find(|process| process.pid == instance.pid)
        {
            process.last_used = Instant::now();
        }
    }

    pub async fn ensure(&self, uri: &str) -> Result<Instance, String> {
        let file = native_path(uri)?;
        let root = project_root(&file)?;
        let (pid, started) = {
            let mut processes = self.processes.lock().await;
            if let Some(process) = processes.get_mut(&root) {
                if process.child.try_wait().ok().flatten().is_none() {
                    process.last_used = Instant::now();
                    (process.pid, false)
                } else {
                    processes.remove(&root);
                    let process = spawn(&root, &file, self.registry.dir())?;
                    let pid = process.pid;
                    processes.insert(root.clone(), process);
                    (pid, true)
                }
            } else {
                let process = spawn(&root, &file, self.registry.dir())?;
                let pid = process.pid;
                processes.insert(root.clone(), process);
                (pid, true)
            }
        };
        if started {
            self.schedule_cleanup(root.clone(), pid);
        }
        match wait_for_instance(&self.registry, pid, self.ready_timeout).await {
            Ok(instance) => Ok(instance),
            Err(error) => {
                self.remove_and_stop(&root, pid).await;
                Err(error)
            }
        }
    }

    fn schedule_cleanup(&self, root: PathBuf, pid: u32) {
        let processes = Arc::downgrade(&self.processes);
        let registry = self.registry.clone();
        let idle_timeout = self.idle_timeout;
        let handoff_delay = self.handoff_delay;
        let watch_interval = self.watch_interval;
        tokio::spawn(async move {
            let mut handoff_started = None;
            loop {
                tokio::time::sleep(watch_interval).await;
                let interactive = registry.list().await.is_ok_and(|instances| {
                    managed_project_id(&instances.instances, pid).is_some_and(|project_id| {
                        has_interactive_instance(&instances.instances, project_id)
                    })
                });
                if interactive {
                    handoff_started.get_or_insert_with(Instant::now);
                } else {
                    handoff_started = None;
                }

                let Some(processes) = processes.upgrade() else {
                    return;
                };
                let mut processes = processes.lock().await;
                let Some(process) = processes.get_mut(&root) else {
                    return;
                };
                if process.pid != pid {
                    return;
                }
                let should_handoff =
                    handoff_started.is_some_and(|started| started.elapsed() >= handoff_delay);
                if !should_handoff && process.last_used.elapsed() < idle_timeout {
                    continue;
                }
                stop(process).await;
                processes.remove(&root);
                return;
            }
        });
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
    if !path.is_file() {
        return Err(format!(
            "path does not exist or is not a regular file: {}",
            path.display()
        ));
    }
    fs::canonicalize(path).map_err(|error| error.to_string())
}

fn project_root(file: &Path) -> Result<PathBuf, String> {
    let start = file
        .parent()
        .ok_or_else(|| format!("file has no parent: {}", file.display()))?;
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

fn spawn(root: &Path, file: &Path, registry: &Path) -> Result<ManagedProcess, String> {
    let socket = std::env::temp_dir().join(format!(
        "vv-mcp-{}-{}.sock",
        std::process::id(),
        NEXT_SOCKET_ID.fetch_add(1, Ordering::Relaxed),
    ));
    let _ = fs::remove_file(&socket);
    let child = Command::new("nvim")
        .arg("--headless")
        .arg("--listen")
        .arg(&socket)
        .arg(file)
        .current_dir(root)
        .env("VV_MCP_MANAGED", "1")
        .env("VV_MCP_REGISTRY", registry)
        .kill_on_drop(true)
        .spawn()
        .map_err(|error| format!("failed to start managed Neovim: {error}"))?;
    let pid = child
        .id()
        .ok_or_else(|| "managed Neovim has no PID".to_owned())?;
    Ok(ManagedProcess {
        child,
        pid,
        socket: socket.to_string_lossy().into_owned(),
        last_used: Instant::now(),
    })
}

async fn stop(process: &mut ManagedProcess) {
    if let Ok(mut client) = NvimClient::connect(&process.socket).await {
        let _: Result<(), _> = client
            .exec_lua("vim.cmd('silent! qa!')", Vec::<String>::new())
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

fn managed_project_id(instances: &[Instance], pid: u32) -> Option<&str> {
    instances
        .iter()
        .find(|instance| instance.kind == "managed" && instance.pid == pid)
        .map(|instance| instance.project_id.as_str())
}

fn has_interactive_instance(instances: &[Instance], project_id: &str) -> bool {
    instances
        .iter()
        .any(|instance| instance.kind == "interactive" && instance.project_id == project_id)
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

    #[test]
    fn detects_interactive_instance_for_managed_project_handoff() {
        let mut interactive = fixture("interactive", "project", "interactive");
        let managed = fixture("managed", "project", "managed");
        assert!(has_interactive_instance(
            &[managed.clone(), interactive.clone()],
            "project"
        ));
        interactive.project_id = "other".into();
        assert!(!has_interactive_instance(
            &[managed, interactive],
            "project"
        ));
    }

    #[test]
    fn finds_managed_project_by_pid() {
        let managed = fixture("managed", "project", "managed");
        let interactive = fixture("interactive", "project", "interactive");
        assert_eq!(
            managed_project_id(&[interactive, managed], 1),
            Some("project")
        );
    }

    #[tokio::test]
    async fn stop_reaps_child_and_removes_socket() {
        let socket = std::env::temp_dir().join(format!(
            "vv-mcp-stop-test-{}-{}.sock",
            std::process::id(),
            NEXT_SOCKET_ID.fetch_add(1, Ordering::Relaxed)
        ));
        let child = Command::new("nvim")
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
            last_used: Instant::now(),
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

    fn fixture(id: &str, project_id: &str, kind: &str) -> Instance {
        Instance {
            instance_id: id.into(),
            project_id: project_id.into(),
            pid: 1,
            socket: "/tmp/nvim.sock".into(),
            cwd: "/tmp/project".into(),
            roots: vec!["/tmp/project".into()],
            lsp_clients: Vec::new(),
            kind: kind.into(),
            updated_at: 1,
        }
    }
}
