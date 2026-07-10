use std::collections::{BTreeMap, BTreeSet};

use serde::Serialize;
use serde_json::Value;

use super::{OutputFormat, model::Truncated, to_json};

#[derive(Debug, Serialize)]
struct DiagnosticItem {
    range: String,
    severity: &'static str,
    message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    source: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    code: Option<String>,
}

#[derive(Debug, Serialize)]
struct DiagnosticOutput {
    diagnostics: BTreeMap<String, Vec<DiagnosticItem>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    truncated: Option<Truncated>,
}

pub(super) fn format(
    operation: &str,
    raw: Value,
    max_results: usize,
    format: OutputFormat,
) -> String {
    let mut items = Vec::new();
    let mut seen = BTreeSet::new();
    for diagnostic in raw["diagnostics"].as_array().into_iter().flatten() {
        let Some(path) = diagnostic["path"].as_str() else {
            continue;
        };
        let Some(range) = compact_range(&diagnostic["range"]) else {
            continue;
        };
        let message = diagnostic["message"].as_str().unwrap_or_default();
        let source = diagnostic["source"].as_str().map(str::to_owned);
        let code = diagnostic["code"]
            .as_str()
            .map(str::to_owned)
            .or_else(|| diagnostic["code"].as_i64().map(|value| value.to_string()));
        let key = (
            path.to_owned(),
            range.clone(),
            message.to_owned(),
            source.clone(),
            code.clone(),
        );
        if seen.insert(key) {
            items.push((
                path.to_owned(),
                DiagnosticItem {
                    range,
                    severity: severity_name(diagnostic["severity"].as_u64().unwrap_or(0)),
                    message: message.to_owned(),
                    source,
                    code,
                },
            ));
        }
    }

    let total = items.len();
    items.truncate(max_results);
    let mut grouped = BTreeMap::<String, Vec<DiagnosticItem>>::new();
    for (path, item) in items {
        grouped.entry(path).or_default().push(item);
    }
    let output = DiagnosticOutput {
        diagnostics: grouped,
        truncated: (total > max_results).then_some(Truncated {
            shown: max_results,
            total,
        }),
    };

    match format {
        OutputFormat::Json => to_json(&output),
        OutputFormat::Markdown => format_markdown(operation, &output),
    }
}

fn format_markdown(operation: &str, output: &DiagnosticOutput) -> String {
    let title = if operation == "diagnostics" {
        "Diagnostics"
    } else {
        "Workspace Diagnostics"
    };
    let mut lines = vec![format!("## {title}")];
    if output.diagnostics.is_empty() {
        lines.push("No diagnostics found.".into());
    } else {
        for (path, diagnostics) in &output.diagnostics {
            lines.push(format!("`{path}`"));
            for diagnostic in diagnostics {
                let source = diagnostic
                    .source
                    .as_ref()
                    .map(|value| format!(", source: `{value}`"))
                    .unwrap_or_default();
                let code = diagnostic
                    .code
                    .as_ref()
                    .map(|value| format!(", code: `{value}`"))
                    .unwrap_or_default();
                lines.push(format!(
                    "- {} {}: {}{}{}",
                    diagnostic.severity, diagnostic.range, diagnostic.message, source, code
                ));
            }
        }
    }
    if let Some(truncated) = &output.truncated {
        lines.push(format!(
            "(Showing {} of {} diagnostics)",
            truncated.shown, truncated.total
        ));
    }
    lines.join("\n")
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

fn severity_name(severity: u64) -> &'static str {
    match severity {
        1 => "error",
        2 => "warning",
        3 => "information",
        4 => "hint",
        _ => "unknown",
    }
}
