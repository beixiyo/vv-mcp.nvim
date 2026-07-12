//! 编辑器实时状态的紧凑 JSON / Markdown 输出

use serde_json::Value;

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
        "list_buffers" => format_buffers(raw, max_results, format),
        "read_buffer" => format_read_buffer(raw, format),
        "get_selection" => format_selection(raw, format),
        _ => format_context(raw, format),
    }
}

fn format_buffers(mut raw: Value, max_results: usize, format: OutputFormat) -> String {
    let buffers = raw["buffers"].as_array().cloned().unwrap_or_default();
    let total = buffers.len();
    let shown = buffers.into_iter().take(max_results).collect::<Vec<_>>();
    let truncated = total > shown.len();

    if let OutputFormat::Json = format {
        raw["buffers"] = Value::from(shown);
        if truncated {
            raw["truncated"] = serde_json::json!({ "shown": max_results, "total": total });
        }
        return to_json(&raw);
    }

    let mut lines = vec!["## Buffers".to_owned()];
    for buffer in &shown {
        let path = buffer["path"].as_str().unwrap_or("[No Name]");
        let mut flags = Vec::new();
        if buffer["current"].as_bool() == Some(true) {
            flags.push("current");
        }
        if buffer["visible"].as_bool() == Some(true) {
            flags.push("visible");
        }
        if buffer["modified"].as_bool() == Some(true) {
            flags.push("modified");
        }
        let clients = client_names(&buffer["lspClients"]);
        lines.push(format!(
            "- `{path}` ({}): {} lines{}{}",
            buffer["bufferId"],
            buffer["lineCount"],
            if flags.is_empty() {
                String::new()
            } else {
                format!(", {}", flags.join(", "))
            },
            if clients.is_empty() {
                String::new()
            } else {
                format!(", LSP: {clients}")
            },
        ));
    }
    if truncated {
        lines.push(format!("(Showing {} of {total} buffers)", shown.len()));
    }
    lines.join("\n")
}

fn format_read_buffer(raw: Value, format: OutputFormat) -> String {
    if let OutputFormat::Json = format {
        return to_json(&raw);
    }

    let path = raw["path"].as_str().unwrap_or("[No Name]");
    let filetype = raw["filetype"].as_str().unwrap_or("");
    let body = raw["lines"]
        .as_array()
        .map(|lines| {
            lines
                .iter()
                .map(|line| line.as_str().unwrap_or_default())
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default();

    let mut out = format!(
        "## Buffer\n`{path}`\n- Lines {}-{} of {}{}\n\n```{filetype}\n{body}\n```",
        raw["startLine"],
        raw["endLine"],
        raw["lineCount"],
        if raw["modified"].as_bool() == Some(true) {
            ", unsaved changes"
        } else {
            ""
        },
    );
    if let Some(truncated) = raw.get("truncated") {
        out.push_str(&format!(
            "\n(Showing {} of {} requested lines)",
            truncated["shown"], truncated["total"]
        ));
    }
    out
}

fn format_selection(raw: Value, format: OutputFormat) -> String {
    if let OutputFormat::Json = format {
        return to_json(&raw);
    }

    let path = raw["path"].as_str().unwrap_or("[No Name]");
    let start = &raw["range"]["start"];
    let end = &raw["range"]["end"];
    format!(
        "## Selection\n`{path}`\n- Mode: {}\n- Range: {}:{}-{}:{}\n\n```\n{}\n```",
        raw["mode"].as_str().unwrap_or("character"),
        start["line"],
        start["character"],
        end["line"],
        end["character"],
        raw["text"].as_str().unwrap_or_default(),
    )
}

fn format_context(raw: Value, format: OutputFormat) -> String {
    if let OutputFormat::Json = format {
        return to_json(&raw);
    }

    let context = &raw["context"];
    let path = context["path"].as_str().unwrap_or("[No Name]");
    let clients = client_names(&context["lspClients"]);
    let mut lines = vec![
        "## Editor Context".to_owned(),
        format!("`{path}`"),
        format!(
            "- Cursor: {}:{}",
            context["cursor"]["line"], context["cursor"]["character"],
        ),
        format!(
            "- Buffer: {} lines total, filetype `{}`{}",
            context["lineCount"],
            context["filetype"].as_str().unwrap_or(""),
            if context["modified"].as_bool() == Some(true) {
                ", unsaved changes"
            } else {
                ""
            },
        ),
        format!("- Mode: `{}`", context["mode"].as_str().unwrap_or("")),
        format!("- CWD: `{}`", context["cwd"].as_str().unwrap_or("")),
    ];
    if !clients.is_empty() {
        lines.push(format!("- LSP: {clients}"));
    }
    lines.join("\n")
}

fn client_names(value: &Value) -> String {
    value
        .as_array()
        .map(|clients| {
            clients
                .iter()
                .filter_map(|client| client.as_str())
                .map(|client| format!("`{client}`"))
                .collect::<Vec<_>>()
                .join(", ")
        })
        .unwrap_or_default()
}
