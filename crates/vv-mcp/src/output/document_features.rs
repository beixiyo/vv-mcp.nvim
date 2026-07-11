//! 文档链接与内联提示的去重、截断和紧凑输出

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Value, json};

use super::{OutputFormat, model::Truncated, to_json};

pub(super) fn format(
    operation: &str,
    raw: Value,
    max_results: usize,
    format: OutputFormat,
) -> String {
    let (clients, errors, mut items) = collect(operation, &raw);
    let total = items.len();
    items.truncate(max_results);
    let truncated = (total > max_results).then_some(Truncated {
        shown: max_results,
        total,
    });

    match format {
        OutputFormat::Json => {
            let mut output = json!({ "clients": clients, "errors": errors });
            output[operation] = json!(items);
            if let Some(truncated) = truncated {
                output["truncated"] = json!(truncated);
            }
            to_json(&output)
        }
        OutputFormat::Markdown => format_markdown(operation, clients, errors, items, truncated),
    }
}

fn collect(operation: &str, raw: &Value) -> (Vec<String>, BTreeMap<String, String>, Vec<Value>) {
    let mut clients = BTreeSet::new();
    let mut errors = BTreeMap::new();
    let mut items = Vec::new();
    let mut seen = BTreeSet::new();

    for response in raw["results"].as_array().into_iter().flatten() {
        let client = response["client"].as_str().unwrap_or("unknown");
        if let Some(error) = response["error"].as_str() {
            errors.insert(client.to_owned(), error.to_owned());
        }
        let before = items.len();
        for item in response["result"].as_array().into_iter().flatten() {
            let compact = if operation == "document_links" {
                compact_link(item)
            } else {
                compact_hint(item)
            };
            if let Some(compact) = compact {
                let fingerprint = compact.to_string();
                if seen.insert(fingerprint) {
                    items.push(compact);
                }
            }
        }
        if items.len() > before {
            clients.insert(client.to_owned());
        }
    }

    (clients.into_iter().collect(), errors, items)
}

fn compact_link(item: &Value) -> Option<Value> {
    Some(json!({
        "range": compact_range(&item["range"])?,
        "target": item["target"].as_str()?,
        "tooltip": item["tooltip"].as_str(),
    }))
}

fn compact_hint(item: &Value) -> Option<Value> {
    let label = match &item["label"] {
        Value::String(label) => label.clone(),
        Value::Array(parts) => parts
            .iter()
            .filter_map(|part| part["value"].as_str())
            .collect::<String>(),
        _ => return None,
    };
    Some(json!({
        "position": compact_position(&item["position"])?,
        "label": label,
        "kind": match item["kind"].as_u64() { Some(1) => "type", Some(2) => "parameter", _ => "other" },
        "tooltip": tooltip(&item["tooltip"]),
    }))
}

fn tooltip(value: &Value) -> Option<&str> {
    value.as_str().or_else(|| value["value"].as_str())
}

fn compact_position(position: &Value) -> Option<String> {
    Some(format!(
        "{}:{}",
        position["line"].as_u64()?,
        position["character"].as_u64()?
    ))
}

fn compact_range(range: &Value) -> Option<String> {
    Some(format!(
        "{}:{}-{}:{}",
        range["start"]["line"].as_u64()?,
        range["start"]["character"].as_u64()?,
        range["end"]["line"].as_u64()?,
        range["end"]["character"].as_u64()?
    ))
}

fn format_markdown(
    operation: &str,
    clients: Vec<String>,
    errors: BTreeMap<String, String>,
    items: Vec<Value>,
    truncated: Option<Truncated>,
) -> String {
    let title = if operation == "document_links" {
        "Document Links"
    } else {
        "Inlay Hints"
    };
    let mut lines = vec![format!("## {title}")];
    if !clients.is_empty() {
        lines.push(format!(
            "Clients: {}",
            clients
                .iter()
                .map(|client| format!("`{client}`"))
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }
    if items.is_empty() {
        lines.push(if operation == "document_links" {
            "No document links found.".to_owned()
        } else {
            "No inlay hints found.".to_owned()
        });
    }
    for item in items {
        if operation == "document_links" {
            lines.push(format!(
                "- {} -> {}{}",
                item["range"].as_str().unwrap_or_default(),
                item["target"].as_str().unwrap_or_default(),
                item["tooltip"]
                    .as_str()
                    .map(|value| format!(": {value}"))
                    .unwrap_or_default()
            ));
        } else {
            lines.push(format!(
                "- {} {}: `{}`{}",
                item["position"].as_str().unwrap_or_default(),
                item["kind"].as_str().unwrap_or("other"),
                item["label"].as_str().unwrap_or_default(),
                item["tooltip"]
                    .as_str()
                    .map(|value| format!(": {value}"))
                    .unwrap_or_default()
            ));
        }
    }
    if let Some(truncated) = truncated {
        lines.push(format!(
            "(Showing {} of {} {})",
            truncated.shown,
            truncated.total,
            if operation == "document_links" {
                "links"
            } else {
                "hints"
            }
        ));
    }
    for (client, error) in errors {
        lines.push(format!("- Error from `{client}`: {error}"));
    }
    lines.join("\n")
}
