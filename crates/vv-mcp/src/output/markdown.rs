//! 通用位置结果与错误对象的 Markdown 渲染

use serde_json::Value;

use super::model::FlattenedLocations;

pub(super) fn format_locations(operation: &str, result: &FlattenedLocations) -> String {
    let mut lines = vec![format!("## {}", title(operation))];

    if !result.clients.is_empty() {
        lines.push(format!(
            "Clients: {}",
            result
                .clients
                .iter()
                .map(|client| format!("`{client}`"))
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }

    if result.locations.is_empty() {
        lines.push(format!("No {} found.", operation.replace('_', " ")));
    } else {
        for (path, ranges) in &result.locations {
            lines.push(format!("- `{path}`: {}", ranges.join(", ")));
        }
    }

    if let Some(truncated) = &result.truncated {
        lines.push(format!(
            "(Showing {} of {} results)",
            truncated.shown, truncated.total
        ));
    }
    for (client, error) in &result.errors {
        lines.push(format!("- Error from `{client}`: {error}"));
    }

    lines.join("\n")
}

pub(super) fn format_error(raw: &Value) -> String {
    let error = &raw["error"];
    let code = error["code"].as_str().unwrap_or("request_failed");
    let message = error["message"].as_str().unwrap_or("Unknown error");
    format!("## Error\n- Code: `{code}`\n- Message: {message}")
}

fn title(operation: &str) -> String {
    operation
        .split('_')
        .map(|part| {
            let mut chars = part.chars();
            chars
                .next()
                .map(|first| first.to_uppercase().collect::<String>() + chars.as_str())
                .unwrap_or_default()
        })
        .collect::<Vec<_>>()
        .join(" ")
}
