//! 文档语义高亮范围与读写类型的紧凑输出

use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::{OutputFormat, to_json};

pub(super) fn format(raw: Value, max_results: usize, format: OutputFormat) -> String {
    let mut clients = BTreeSet::new();
    let mut seen = BTreeSet::new();
    let mut items = Vec::new();
    for response in raw["results"].as_array().into_iter().flatten() {
        let before = items.len();
        for highlight in response["result"].as_array().into_iter().flatten() {
            if let Some(range) = compact_range(&highlight["range"]) {
                let kind = highlight_kind(highlight["kind"].as_u64());
                if seen.insert((range.clone(), kind)) {
                    items.push(json!({ "range": range, "kind": kind }));
                }
            }
        }
        if items.len() > before
            && let Some(client) = response["client"].as_str()
        {
            clients.insert(client.to_owned());
        }
    }
    let total = items.len();
    items.truncate(max_results);
    let clients = clients.into_iter().collect::<Vec<_>>();
    let truncated = (total > max_results).then(|| json!({ "shown": max_results, "total": total }));

    match format {
        OutputFormat::Json => {
            let mut output = json!({
              "clients": clients,
              "path": raw["path"],
              "highlights": items,
            });
            if let Some(truncated) = truncated {
                output["truncated"] = truncated;
            }
            to_json(&output)
        }
        OutputFormat::Markdown => {
            let mut lines = vec![
                "## Document Highlights".to_owned(),
                format!(
                    "Clients: {}",
                    clients
                        .iter()
                        .map(|client| format!("`{client}`"))
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
                format!("`{}`", raw["path"].as_str().unwrap_or_default()),
            ];
            for item in items {
                lines.push(format!(
                    "- {}: {}",
                    item["kind"].as_str().unwrap_or("text"),
                    item["range"].as_str().unwrap_or_default()
                ));
            }
            if let Some(truncated) = truncated {
                lines.push(format!(
                    "(Showing {} of {} highlights)",
                    truncated["shown"], truncated["total"]
                ));
            }
            lines.join("\n")
        }
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

fn highlight_kind(kind: Option<u64>) -> &'static str {
    match kind {
        Some(2) => "read",
        Some(3) => "write",
        _ => "text",
    }
}
