//! 重命名预检、预览与应用结果的紧凑输出

use std::collections::BTreeMap;

use serde_json::{Value, json};

use super::{OutputFormat, to_json};

pub(super) fn format(
    operation: &str,
    raw: Value,
    max_results: usize,
    format: OutputFormat,
) -> String {
    match operation {
        "prepare_rename" => format_prepare(raw, format),
        "rename_preview" => format_preview(raw, max_results, format),
        "rename_apply" => format_apply(raw, format),
        _ => String::new(),
    }
}

fn format_prepare(raw: Value, format: OutputFormat) -> String {
    let mut items = Vec::new();
    for response in raw["results"].as_array().into_iter().flatten() {
        let Some(client) = response["client"].as_str() else {
            continue;
        };
        let result = &response["result"];
        let range = result
            .get("range")
            .or_else(|| result.get("start").map(|_| result))
            .and_then(compact_range);
        items.push(json!({
          "client": client,
          "range": range,
          "placeholder": result["placeholder"].as_str(),
        }));
    }
    match format {
        OutputFormat::Json => to_json(&json!({ "items": items })),
        OutputFormat::Markdown => {
            let mut lines = vec!["## Prepare Rename".to_owned()];
            for item in items {
                lines.push(format!(
                    "- `{}`: {}{}",
                    item["client"].as_str().unwrap_or("unknown"),
                    item["range"].as_str().unwrap_or("supported"),
                    item["placeholder"]
                        .as_str()
                        .map(|value| format!(", placeholder: `{value}`"))
                        .unwrap_or_default()
                ));
            }
            lines.join("\n")
        }
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
      "renameId": raw["renameId"],
      "client": raw["client"],
      "newName": raw["newName"],
      "filesChanged": raw["filesChanged"],
      "editsCount": raw["editsCount"],
      "expiresAt": raw["expiresAt"],
      "changes": grouped,
    });
    if let Some(truncated) = truncated {
        output["truncated"] = truncated;
    }

    match format {
        OutputFormat::Json => to_json(&output),
        OutputFormat::Markdown => {
            let mut lines = vec![
                "## Rename Preview".to_owned(),
                format!("Client: `{}`", raw["client"].as_str().unwrap_or("unknown")),
                format!(
                    "Rename ID: `{}`",
                    raw["renameId"].as_str().unwrap_or_default()
                ),
                format!(
                    "New name: `{}`; {} files, {} edits",
                    raw["newName"].as_str().unwrap_or_default(),
                    raw["filesChanged"],
                    raw["editsCount"]
                ),
            ];
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
            "## Rename Applied\n- Rename ID: `{}`\n- {} files, {} edits\n- Saved to disk: `{}`",
            raw["renameId"].as_str().unwrap_or_default(),
            raw["filesChanged"],
            raw["editsCount"],
            raw["saved"].as_bool().unwrap_or(false)
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
