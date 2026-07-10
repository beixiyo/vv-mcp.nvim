use typed_path::{Utf8UnixPath, Utf8WindowsPath};

use super::Instance;

#[derive(Debug, thiserror::Error)]
pub enum ResolveError {
    #[error("Neovim instance not found: {0}")]
    NotFound(String),
    #[error("multiple Neovim instances match; pass instanceId explicitly: {0}")]
    Ambiguous(String),
    #[error("instanceId or uri is required")]
    MissingSelector,
}

pub fn resolve_instance<'a>(
    instances: &'a [Instance],
    instance_id: Option<&str>,
    uri: Option<&str>,
) -> Result<&'a Instance, ResolveError> {
    if let Some(instance_id) = instance_id {
        return instances
            .iter()
            .find(|instance| instance.instance_id == instance_id)
            .ok_or_else(|| ResolveError::NotFound(instance_id.into()));
    }

    let target = normalize_wire_path(uri.ok_or(ResolveError::MissingSelector)?);
    let mut matches = instances
        .iter()
        .filter_map(|instance| {
            let length = instance
                .roots
                .iter()
                .map(|root| normalize_wire_path(root))
                .filter(|root| is_path_prefix(root, &target))
                .map(|root| root.len())
                .max()?;
            Some((instance, length))
        })
        .collect::<Vec<_>>();

    matches.sort_by_key(|(_, length)| std::cmp::Reverse(*length));
    let Some((selected, selected_length)) = matches.first().copied() else {
        return Err(ResolveError::NotFound(target));
    };
    let tied = matches
        .iter()
        .take_while(|(_, length)| *length == selected_length)
        .map(|(instance, _)| instance.instance_id.as_str())
        .collect::<Vec<_>>();
    if tied.len() > 1 {
        return Err(ResolveError::Ambiguous(tied.join(", ")));
    }

    Ok(selected)
}

fn normalize_wire_path(input: &str) -> String {
    let input = input.strip_prefix("file://").unwrap_or(input);
    if looks_windows(input) {
        Utf8WindowsPath::new(input)
            .normalize()
            .to_string()
            .replace('\\', "/")
    } else {
        Utf8UnixPath::new(input).normalize().to_string()
    }
}

fn looks_windows(path: &str) -> bool {
    path.as_bytes().get(1) == Some(&b':') || path.contains('\\') || path.starts_with("//")
}

fn is_path_prefix(root: &str, target: &str) -> bool {
    let case_insensitive = looks_windows(root) || looks_windows(target);
    let (root, target) = if case_insensitive {
        (root.to_lowercase(), target.to_lowercase())
    } else {
        (root.to_owned(), target.to_owned())
    };

    target == root
        || target
            .strip_prefix(&root)
            .is_some_and(|rest| rest.starts_with('/'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chooses_longest_workspace_prefix() {
        let instances = vec![fixture("parent", "/code"), fixture("child", "/code/app")];
        assert_eq!(
            resolve_instance(&instances, None, Some("/code/app/src/main.rs"))
                .unwrap()
                .instance_id,
            "child"
        );
    }

    #[test]
    fn normalizes_windows_wire_paths() {
        let instances = vec![fixture("windows", r"C:\Users\es\code")];
        assert_eq!(
            resolve_instance(&instances, None, Some("c:/Users/es/code/src/main.rs"))
                .unwrap()
                .instance_id,
            "windows"
        );
    }

    #[test]
    fn reports_ambiguous_same_project_instances() {
        let instances = vec![fixture("one", "/code/app"), fixture("two", "/code/app")];
        assert!(matches!(
            resolve_instance(&instances, None, Some("/code/app/main.rs")),
            Err(ResolveError::Ambiguous(_))
        ));
    }

    fn fixture(id: &str, root: &str) -> Instance {
        Instance {
            instance_id: id.into(),
            project_id: "project".into(),
            pid: 1,
            socket: "/tmp/nvim".into(),
            cwd: root.into(),
            roots: vec![root.into()],
            lsp_clients: Vec::new(),
            updated_at: 1,
        }
    }
}
