//! 调用层级节点与单层调用关系的紧凑输出

use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::{OutputFormat, model::Truncated, to_json};

pub(super) fn format(
    operation: &str,
    raw: Value,
    max_results: usize,
    format: OutputFormat,
) -> String {
    let mut items = if operation == "prepare_call_hierarchy" {
        raw["items"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(compact_node)
            .collect::<Vec<_>>()
    } else {
        raw["calls"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(compact_call)
            .collect::<Vec<_>>()
    };
    items.sort_by_key(call_priority);
    let total = items.len();
    items.truncate(max_results);
    let truncated = (total > max_results).then_some(Truncated {
        shown: max_results,
        total,
    });

    match format {
        OutputFormat::Json => {
            let mut output = json!({ "items": items });
            if operation != "prepare_call_hierarchy" {
                output["client"] = raw["client"].clone();
                output["sourceCallId"] = raw["sourceCallId"].clone();
            }
            if let Some(truncated) = truncated {
                output["truncated"] = json!(truncated);
            }
            to_json(&output)
        }
        OutputFormat::Markdown => format_markdown(operation, &raw, items, truncated),
    }
}

fn compact_call(call: &Value) -> Option<Value> {
    let mut node = compact_node(&call["node"])?;
    node["fromRanges"] = json!(
        call["fromRanges"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(compact_range)
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect::<Vec<_>>()
    );
    Some(node)
}

fn compact_node(node: &Value) -> Option<Value> {
    Some(json!({
        "callId": node["callId"].as_str()?,
        "client": node["client"].as_str(),
        "name": node["name"].as_str()?,
        "kind": symbol_kind(node["kind"].as_u64()),
        "origin": node["origin"].as_str().unwrap_or("external"),
        "path": node["uri"].as_str()?,
        "range": compact_range(&node["range"])?,
        "selectionRange": compact_range(&node["selectionRange"]),
        "detail": node["detail"].as_str(),
        "expiresAt": node["expiresAt"].as_u64(),
    }))
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
    raw: &Value,
    items: Vec<Value>,
    truncated: Option<Truncated>,
) -> String {
    let title = match operation {
        "prepare_call_hierarchy" => "Prepare Call Hierarchy",
        "incoming_calls" => "Incoming Calls",
        _ => "Outgoing Calls",
    };
    let mut lines = vec![format!("## {title}")];
    if let Some(client) = raw["client"].as_str() {
        lines.push(format!("Client: `{client}`"));
    }
    if items.is_empty() {
        lines.push("No calls found.".to_owned());
    }
    for item in items {
        lines.push(format!(
            "- `{}` ({}, {}) at `{}`: {}{}\n  Call ID: `{}`{}",
            item["name"].as_str().unwrap_or("unknown"),
            item["kind"].as_str().unwrap_or("Unknown"),
            item["origin"].as_str().unwrap_or("external"),
            item["path"].as_str().unwrap_or_default(),
            item["selectionRange"]
                .as_str()
                .or_else(|| item["range"].as_str())
                .unwrap_or_default(),
            item["client"]
                .as_str()
                .map(|client| format!(", client: `{client}`"))
                .unwrap_or_default(),
            item["callId"].as_str().unwrap_or_default(),
            item["fromRanges"]
                .as_array()
                .filter(|ranges| !ranges.is_empty())
                .map(|ranges| format!(
                    "\n  Call sites: {}",
                    ranges
                        .iter()
                        .filter_map(Value::as_str)
                        .collect::<Vec<_>>()
                        .join(", ")
                ))
                .unwrap_or_default()
        ));
    }
    if let Some(truncated) = truncated {
        lines.push(format!(
            "(Showing {} of {} calls)",
            truncated.shown, truncated.total
        ));
    }
    lines.join("\n")
}

fn call_priority(item: &Value) -> (u8, u8) {
    let origin = match item["origin"].as_str() {
        Some("workspace") => 0,
        Some("dependency") => 1,
        _ => 2,
    };
    let kind = match item["kind"].as_str() {
        Some("Function") | Some("Constructor") => 0,
        Some("Method") => 1,
        _ => 2,
    };
    (origin, kind)
}

fn symbol_kind(kind: Option<u64>) -> &'static str {
    const KINDS: [&str; 26] = [
        "File",
        "Module",
        "Namespace",
        "Package",
        "Class",
        "Method",
        "Property",
        "Field",
        "Constructor",
        "Enum",
        "Interface",
        "Function",
        "Variable",
        "Constant",
        "String",
        "Number",
        "Boolean",
        "Array",
        "Object",
        "Key",
        "Null",
        "EnumMember",
        "Struct",
        "Event",
        "Operator",
        "TypeParameter",
    ];
    kind.and_then(|kind| KINDS.get(kind.saturating_sub(1) as usize))
        .copied()
        .unwrap_or("Unknown")
}
