//! 从状态目录读取实例，并通过真实 RPC 探测清理失效注册文件

use std::{
    fs,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result};

use super::{Instance, InstanceList};
use crate::nvim::NvimClient;

#[derive(Clone, Debug)]
pub struct Registry {
    dir: PathBuf,
}

impl Registry {
    pub fn new(dir: Option<PathBuf>) -> Result<Self> {
        let dir = match dir {
            Some(dir) => dir,
            None => default_registry_dir()?,
        };

        Ok(Self { dir })
    }

    pub async fn list(&self) -> Result<InstanceList> {
        let entries = self.load()?;
        let mut instances = Vec::new();

        for (path, instance) in entries {
            match NvimClient::probe(&instance.socket).await {
                Ok(probe) if probe.pid == instance.pid => instances.push(instance),
                Ok(_) => {
                    let _ = fs::remove_file(path);
                }
                Err(error) if error.proves_instance_is_stale() => {
                    let _ = fs::remove_file(path);
                }
                Err(_) => {}
            }
        }

        sort_instances(&mut instances);
        Ok(InstanceList { instances })
    }

    fn load(&self) -> Result<Vec<(PathBuf, Instance)>> {
        if !self.dir.exists() {
            return Ok(Vec::new());
        }

        let mut entries = Vec::new();
        for entry in fs::read_dir(&self.dir)
            .with_context(|| format!("failed to read registry: {}", self.dir.display()))?
        {
            let path = entry?.path();
            if path.extension().and_then(|value| value.to_str()) != Some("json") {
                continue;
            }

            let raw = match fs::read_to_string(&path) {
                Ok(raw) => raw,
                Err(_) => continue,
            };
            if let Ok(instance) = serde_json::from_str::<Instance>(&raw) {
                entries.push((path, instance))
            }
        }

        Ok(entries)
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }
}

fn sort_instances(instances: &mut [Instance]) {
    instances.sort_by(|left, right| {
        right
            .updated_at
            .cmp(&left.updated_at)
            .then_with(|| left.instance_id.cmp(&right.instance_id))
    });
}

fn default_registry_dir() -> Result<PathBuf> {
    if let Some(path) = std::env::var_os("XDG_STATE_HOME") {
        return Ok(PathBuf::from(path).join("nvim/vv-mcp/instances"));
    }

    if cfg!(windows) {
        let local_app_data = std::env::var_os("LOCALAPPDATA")
            .context("VV_MCP_REGISTRY or LOCALAPPDATA is required")?;
        return Ok(PathBuf::from(local_app_data).join("nvim-data/vv-mcp/instances"));
    }

    let home = std::env::var_os("HOME").context("VV_MCP_REGISTRY or HOME is required")?;
    Ok(PathBuf::from(home).join(".local/state/nvim/vv-mcp/instances"))
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        time::{SystemTime, UNIX_EPOCH},
    };

    use super::*;

    #[test]
    fn loads_and_sorts_valid_instances() {
        let dir = std::env::temp_dir().join(format!(
            "vv-mcp-registry-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
        ));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("old.json"), fixture("old:1", 1)).unwrap();
        fs::write(dir.join("new.json"), fixture("new:2", 2)).unwrap();
        fs::write(dir.join("broken.json"), "{").unwrap();

        let registry = Registry::new(Some(dir.clone())).unwrap();
        let mut instances = registry
            .load()
            .unwrap()
            .into_iter()
            .map(|(_, instance)| instance)
            .collect::<Vec<_>>();
        sort_instances(&mut instances);

        assert_eq!(instances.len(), 2);
        assert_eq!(instances[0].instance_id, "new:2");
        assert_eq!(instances[1].instance_id, "old:1");

        fs::remove_dir_all(dir).unwrap();
    }

    fn fixture(instance_id: &str, updated_at: u64) -> String {
        serde_json::json!({
          "instanceId": instance_id,
          "projectId": "project",
          "pid": 1,
          "socket": "/tmp/nvim.sock",
          "cwd": "/tmp/project",
          "roots": ["/tmp/project"],
          "lspClients": ["test-lsp"],
          "updatedAt": updated_at,
        })
        .to_string()
    }
}
