//! 文档与工作区符号的扁平化、分组和截断输出

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Value, json};

use super::{OutputFormat, to_json};

pub(super) fn format(
    operation: &str,
    raw: Value,
    max_results: usize,
    format: OutputFormat,
) -> String {
    let mut clients = BTreeSet::new();
    let mut items = Vec::new();
    let default_path = raw["path"].as_str().unwrap_or_default();
    for response in raw["results"].as_array().into_iter().flatten() {
        let previous_len = items.len();
        collect_symbols(&response["result"], default_path, None, &mut items);
        if items.len() > previous_len
            && let Some(client) = response["client"].as_str()
        {
            clients.insert(client.to_owned());
        }
    }

    let total = items.len();
    items.truncate(max_results);
    let mut grouped = BTreeMap::<String, Vec<Value>>::new();
    for (path, item) in items {
        grouped.entry(path).or_default().push(item);
    }
    let truncated = (total > max_results).then(|| json!({ "shown": max_results, "total": total }));
    let clients = clients.into_iter().collect::<Vec<_>>();

    match format {
        OutputFormat::Json => {
            let mut output = json!({ "clients": clients, "symbols": grouped });
            if let Some(truncated) = truncated {
                output["truncated"] = truncated;
            }
            to_json(&output)
        }
        OutputFormat::Markdown => {
            let title = if operation == "document_symbols" {
                "Document Symbols"
            } else {
                "Workspace Symbols"
            };
            let mut lines = vec![format!("## {title}")];
            lines.push(format!(
                "Clients: {}",
                clients
                    .iter()
                    .map(|client| format!("`{client}`"))
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
            for (path, symbols) in grouped {
                lines.push(format!("`{path}`"));
                for symbol in symbols {
                    let name = symbol["name"].as_str().unwrap_or("unknown");
                    let kind = symbol["kind"].as_str().unwrap_or("Unknown");
                    let range = symbol["range"].as_str().unwrap_or("unknown");
                    let container = symbol["container"]
                        .as_str()
                        .map(|value| format!(", in `{value}`"))
                        .unwrap_or_default();
                    lines.push(format!("- `{name}` ({kind}): {range}{container}"));
                }
            }
            if let Some(truncated) = truncated {
                lines.push(format!(
                    "(Showing {} of {} symbols)",
                    truncated["shown"], truncated["total"]
                ));
            }
            lines.join("\n")
        }
    }
}

fn collect_symbols(
    value: &Value,
    default_path: &str,
    parent: Option<&str>,
    items: &mut Vec<(String, Value)>,
) {
    if let Some(symbols) = value.as_array() {
        for symbol in symbols {
            collect_symbol(symbol, default_path, parent, items);
        }
    }
}

fn collect_symbol(
    symbol: &Value,
    default_path: &str,
    parent: Option<&str>,
    items: &mut Vec<(String, Value)>,
) {
    let path = symbol["location"]["uri"]
        .as_str()
        .or_else(|| symbol["uri"].as_str())
        .unwrap_or(default_path);
    let range = symbol
        .get("selectionRange")
        .or_else(|| symbol.get("range"))
        .or_else(|| symbol["location"].get("range"));
    let name = symbol["name"].as_str().unwrap_or("unknown");
    let mut item = json!({
      "name": name,
      "kind": kind_name(symbol["kind"].as_u64().unwrap_or(0)),
    });
    if let Some(range) = range.and_then(compact_range) {
        item["range"] = Value::String(range);
    }
    let container = symbol["containerName"].as_str().or(parent);
    if let Some(container) = container {
        item["container"] = Value::String(container.to_owned());
    }
    if let Some(detail) = symbol["detail"].as_str() {
        item["detail"] = Value::String(detail.to_owned());
    }
    items.push((path.to_owned(), item));

    if let Some(children) = symbol["children"].as_array() {
        for child in children {
            collect_symbol(child, default_path, Some(name), items);
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

fn kind_name(kind: u64) -> &'static str {
    const KINDS: [&str; 27] = [
        "Unknown",
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
    KINDS.get(kind as usize).copied().unwrap_or("Unknown")
}
