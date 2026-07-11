use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::{OutputFormat, to_json};

pub(super) fn format(
    operation: &str,
    raw: Value,
    max_results: usize,
    format: OutputFormat,
) -> String {
    let (clients, results) = responses(&raw, operation);
    let mut items = match operation {
        "hover" => flatten_hover(results),
        "signature_help" => flatten_signatures(results),
        _ => Vec::new(),
    };
    let total = items.len();
    items.truncate(max_results);
    let truncated = (total > max_results).then(|| json!({ "shown": max_results, "total": total }));

    match format {
        OutputFormat::Json => {
            let mut output = json!({ "clients": clients, "items": items });
            if let Some(truncated) = truncated {
                output["truncated"] = truncated;
            }
            to_json(&output)
        }
        OutputFormat::Markdown => {
            let title = if operation == "hover" {
                "Hover"
            } else {
                "Signature Help"
            };
            let mut lines = vec![format!("## {title}"), format_clients(&clients)];
            if items.is_empty() {
                lines.push("No information found.".into());
            } else {
                for item in items {
                    if let Some(label) = item.get("label").and_then(Value::as_str) {
                        lines.push(format!("- `{label}`"));
                        if let Some(active_parameter) =
                            item.get("activeParameter").and_then(Value::as_u64)
                        {
                            let active_label = item["parameters"]
                                .as_array()
                                .and_then(|parameters| {
                                    parameters.get(active_parameter as usize - 1)
                                })
                                .and_then(|parameter| parameter["label"].as_str())
                                .unwrap_or("unknown");
                            lines.push(format!(
                                "  Active parameter: {active_parameter} (`{active_label}`)"
                            ));
                        }
                        if let Some(documentation) =
                            item.get("documentation").and_then(Value::as_str)
                        {
                            lines.push(format!("  {documentation}"));
                        }
                        for (index, parameter) in item["parameters"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .enumerate()
                        {
                            let label = parameter["label"].as_str().unwrap_or("unknown");
                            let documentation = parameter["documentation"]
                                .as_str()
                                .map(|value| format!(": {value}"))
                                .unwrap_or_default();
                            lines.push(format!(
                                "  - Parameter {}: `{label}`{documentation}",
                                index + 1
                            ));
                        }
                    } else if let Some(text) = item.as_str() {
                        lines.push(text.to_owned());
                    }
                }
            }
            if let Some(truncated) = truncated {
                lines.push(format!(
                    "(Showing {} of {} results)",
                    truncated["shown"], truncated["total"]
                ));
            }
            lines.join("\n")
        }
    }
}

fn responses<'a>(raw: &'a Value, operation: &str) -> (Vec<String>, Vec<&'a Value>) {
    let mut clients = BTreeSet::new();
    let mut results = Vec::new();
    for response in raw["results"].as_array().into_iter().flatten() {
        let result = &response["result"];
        let has_content = match operation {
            "hover" => markup_text(&result["contents"]).is_some(),
            "signature_help" => result["signatures"]
                .as_array()
                .is_some_and(|signatures| !signatures.is_empty()),
            _ => false,
        };
        if has_content {
            if let Some(client) = response["client"].as_str() {
                clients.insert(client.to_owned());
            }
            results.push(result);
        }
    }
    (clients.into_iter().collect(), results)
}

fn flatten_hover(results: Vec<&Value>) -> Vec<Value> {
    results
        .into_iter()
        .filter_map(|result| markup_text(&result["contents"]).map(Value::String))
        .collect()
}

fn flatten_signatures(results: Vec<&Value>) -> Vec<Value> {
    let mut items = Vec::new();
    for result in results {
        let active_signature = result["activeSignature"].as_u64().unwrap_or(0) as usize;
        let active_parameter = result["activeParameter"].as_u64();
        for (index, signature) in result["signatures"]
            .as_array()
            .into_iter()
            .flatten()
            .enumerate()
        {
            let mut item = json!({
              "label": signature["label"],
              "active": index == active_signature,
            });
            if let Some(documentation) = markup_text(&signature["documentation"]) {
                item["documentation"] = Value::String(documentation);
            }
            let signature_active_parameter = signature["activeParameter"].as_u64();
            if index == active_signature
                && let Some(active_parameter) = active_parameter.or(signature_active_parameter)
            {
                item["activeParameter"] = Value::from(active_parameter + 1);
            }
            if let Some(parameters) = signature["parameters"].as_array() {
                item["parameters"] = Value::Array(
                    parameters
                        .iter()
                        .map(|parameter| {
                            let mut compact = json!({
                              "label": parameter_label(&parameter["label"], signature["label"].as_str()),
                            });
                            if let Some(documentation) = markup_text(&parameter["documentation"]) {
                                compact["documentation"] = Value::String(documentation);
                            }
                            compact
                        })
                        .collect(),
                );
            }
            items.push(item);
        }
    }
    items
}

fn parameter_label(label: &Value, signature: Option<&str>) -> String {
    if let Some(label) = label.as_str() {
        return label.to_owned();
    }
    let Some(offsets) = label.as_array() else {
        return String::new();
    };
    let (Some(start), Some(end), Some(signature)) = (
        offsets.first().and_then(Value::as_u64),
        offsets.get(1).and_then(Value::as_u64),
        signature,
    ) else {
        return String::new();
    };
    signature
        .get(start as usize..end as usize)
        .unwrap_or_default()
        .to_owned()
}

fn markup_text(value: &Value) -> Option<String> {
    if let Some(text) = value.as_str() {
        return (!text.is_empty()).then(|| text.to_owned());
    }
    if let Some(text) = value.get("value").and_then(Value::as_str) {
        return (!text.is_empty()).then(|| text.to_owned());
    }
    let parts = value
        .as_array()?
        .iter()
        .filter_map(markup_text)
        .collect::<Vec<_>>();
    (!parts.is_empty()).then(|| parts.join("\n\n"))
}

fn format_clients(clients: &[String]) -> String {
    format!(
        "Clients: {}",
        clients
            .iter()
            .map(|client| format!("`{client}`"))
            .collect::<Vec<_>>()
            .join(", ")
    )
}
