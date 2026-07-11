//! 文件与目录重命名事务的紧凑 JSON / Markdown 输出

use std::collections::BTreeMap;

use serde_json::{Value, json};

use super::{OutputFormat, to_json};

pub(super) fn format(
    operation: &str,
    raw: Value,
    max_results: usize,
    format: OutputFormat,
) -> String {
    if raw.get("error").is_some() {
        return match format {
            OutputFormat::Json => raw.to_string(),
            OutputFormat::Markdown => super::markdown::format_error(&raw),
        };
    }
    match operation {
        "rename_resource_preview" => format_preview(raw, max_results, format),
        "rename_resource_apply" => format_apply(raw, format),
        _ => String::new(),
    }
}

fn format_preview(raw: Value, max_results: usize, format: OutputFormat) -> String {
    let mut changes = Vec::new();
    for (path, ranges) in raw["changes"].as_object().into_iter().flatten() {
        for range in ranges.as_array().into_iter().flatten() {
            if let Some(range) = compact_range(range) {
                changes.push((path.to_owned(), range));
            }
        }
    }
    let total = changes.len();
    changes.truncate(max_results);
    let mut grouped = BTreeMap::<String, Vec<String>>::new();
    for (path, range) in changes {
        grouped.entry(path).or_default().push(range);
    }
    let truncated = (total > max_results).then(|| json!({ "shown": max_results, "total": total }));
    let mut output = json!({
      "resourceRenameId": raw["resourceRenameId"],
      "oldUri": raw["oldUri"],
      "newUri": raw["newUri"],
      "resourceType": raw["resourceType"],
      "clients": raw["clients"],
      "filesChanged": raw["filesChanged"],
      "editsCount": raw["editsCount"],
      "changes": grouped,
    });
    if let Some(truncated) = truncated {
        output["truncated"] = truncated;
    }
    match format {
        OutputFormat::Json => to_json(&output),
        OutputFormat::Markdown => {
            let mut lines = vec![
                "## Resource Rename Preview".to_owned(),
                format!(
                    "Resource Rename ID: `{}`",
                    raw["resourceRenameId"].as_str().unwrap_or_default()
                ),
                format!(
                    "- `{}` -> `{}` ({})",
                    raw["oldUri"].as_str().unwrap_or_default(),
                    raw["newUri"].as_str().unwrap_or_default(),
                    raw["resourceType"].as_str().unwrap_or("resource")
                ),
                format!(
                    "- {} files, {} edits",
                    raw["filesChanged"], raw["editsCount"]
                ),
            ];
            if let Some(clients) = raw["clients"].as_array() {
                let names = clients.iter().filter_map(Value::as_str).collect::<Vec<_>>();
                if !names.is_empty() {
                    lines.push(format!("- Clients: `{}`", names.join("`, `")));
                }
            }
            for (path, ranges) in grouped {
                lines.push(format!("- `{path}`: {}", ranges.join(", ")));
            }
            if let Some(truncated) = output.get("truncated") {
                lines.push(format!(
                    "(Showing {} of {} edits)",
                    truncated["shown"], truncated["total"]
                ));
            }
            lines.join("\n")
        }
    }
}

fn format_apply(raw: Value, format: OutputFormat) -> String {
    match format {
        OutputFormat::Json => to_json(&raw),
        OutputFormat::Markdown => format!(
            "## Resource Rename Applied\n- Resource Rename ID: `{}`\n- `{}` -> `{}`\n- {} files, {} edits\n- Saved to disk: `{}`",
            raw["resourceRenameId"].as_str().unwrap_or_default(),
            raw["oldUri"].as_str().unwrap_or_default(),
            raw["newUri"].as_str().unwrap_or_default(),
            raw["filesChanged"],
            raw["editsCount"],
            raw["saved"].as_bool().unwrap_or(false),
        ),
    }
}

fn compact_range(range: &Value) -> Option<String> {
    Some(format!(
        "{}:{}-{}:{}",
        range["start"]["line"].as_u64()?,
        range["start"]["character"].as_u64()?,
        range["end"]["line"].as_u64()?,
        range["end"]["character"].as_u64()?,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_resource_rename_preview_and_caps_edits() {
        let raw = json!({
          "resourceRenameId": "resource-1",
          "oldUri": "/code/a.ts",
          "newUri": "/code/b.ts",
          "resourceType": "file",
          "clients": ["tsgo"],
          "filesChanged": 1,
          "editsCount": 2,
          "changes": {
            "/code/use.ts": [
              { "start": { "line": 1, "character": 2 }, "end": { "line": 1, "character": 5 } },
              { "start": { "line": 3, "character": 2 }, "end": { "line": 3, "character": 5 } }
            ]
          }
        });
        let output = format("rename_resource_preview", raw, 1, OutputFormat::Json);
        let output: Value = serde_json::from_str(&output).unwrap();
        assert_eq!(output["resourceRenameId"], "resource-1");
        assert_eq!(output["truncated"], json!({ "shown": 1, "total": 2 }));
    }
}
