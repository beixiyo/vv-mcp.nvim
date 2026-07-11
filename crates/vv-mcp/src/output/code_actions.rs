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
        "code_actions" => format_list(raw, max_results, format),
        "code_action_preview" | "file_quickfix_preview" => {
            format_preview(operation, raw, max_results, format)
        }
        "code_action_apply" => format_apply(raw, format),
        _ => String::new(),
    }
}

fn format_list(raw: Value, max_results: usize, format: OutputFormat) -> String {
    let total = raw["items"].as_array().map_or(0, Vec::len);
    let items = raw["items"]
        .as_array()
        .map(|items| items.iter().take(max_results).cloned().collect::<Vec<_>>())
        .unwrap_or_default();
    let truncated = (total > max_results).then(|| json!({ "shown": max_results, "total": total }));
    match format {
        OutputFormat::Json => {
            let mut output = json!({ "actions": items, "errors": raw["errors"] });
            if let Some(truncated) = truncated {
                output["truncated"] = truncated;
            }
            to_json(&output)
        }
        OutputFormat::Markdown => {
            let mut lines = vec!["## Code Actions".to_owned()];
            for item in items {
                let preferred = item["preferred"].as_bool().unwrap_or(false);
                lines.push(format!(
                    "- `{}`: {}{}, client: `{}`{}",
                    item["actionId"].as_str().unwrap_or_default(),
                    item["title"].as_str().unwrap_or("Untitled action"),
                    item["kind"]
                        .as_str()
                        .map(|kind| format!(" ({kind})"))
                        .unwrap_or_default(),
                    item["client"].as_str().unwrap_or("unknown"),
                    if preferred { ", preferred" } else { "" }
                ));
            }
            for (client, error) in raw["errors"].as_object().into_iter().flatten() {
                lines.push(format!(
                    "- Error from `{client}`: {}",
                    error.as_str().unwrap_or("unknown error")
                ));
            }
            if let Some(truncated) = truncated {
                lines.push(format!(
                    "(Showing {} of {} actions)",
                    truncated["shown"], truncated["total"]
                ));
            }
            lines.join("\n")
        }
    }
}

fn format_preview(operation: &str, raw: Value, max_results: usize, format: OutputFormat) -> String {
    let mut edits = Vec::new();
    for (path, ranges) in raw["changes"].as_object().into_iter().flatten() {
        for range in ranges.as_array().into_iter().flatten() {
            if let Some(range) = compact_range(range) {
                edits.push((path.to_owned(), range));
            }
        }
    }
    let total = edits.len();
    edits.truncate(max_results);
    let mut changes = BTreeMap::<String, Vec<String>>::new();
    for (path, range) in edits {
        changes.entry(path).or_default().push(range);
    }
    let truncated = (total > max_results).then(|| json!({ "shown": max_results, "total": total }));
    let titles = raw["titles"]
        .as_array()
        .map(|titles| titles.iter().take(max_results).cloned().collect::<Vec<_>>())
        .unwrap_or_default();
    let mut output = json!({
      "actionId": raw["actionId"],
      "title": raw["title"],
      "kind": raw["kind"],
      "clients": raw["clients"],
      "titles": titles,
      "actionsCount": raw["actionsCount"],
      "filesChanged": raw["filesChanged"],
      "editsCount": raw["editsCount"],
      "expiresAt": raw["expiresAt"],
      "changes": changes,
    });
    if let Some(truncated) = truncated {
        output["truncated"] = truncated;
    }
    match format {
        OutputFormat::Json => to_json(&output),
        OutputFormat::Markdown => {
            let title = if operation == "file_quickfix_preview" {
                "File Quickfix Preview"
            } else {
                "Code Action Preview"
            };
            let mut lines = vec![
                format!("## {title}"),
                format!(
                    "Action ID: `{}`",
                    raw["actionId"].as_str().unwrap_or_default()
                ),
                format!("{} files, {} edits", raw["filesChanged"], raw["editsCount"]),
            ];
            if let Some(action_title) = raw["title"].as_str() {
                lines.insert(2, format!("Title: {action_title}"));
            }
            for (path, ranges) in changes {
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
            "## Code Action Applied\n- Action ID: `{}`\n- {} files, {} edits\n- Saved to disk: `{}`",
            raw["actionId"].as_str().unwrap_or_default(),
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
