use std::collections::{BTreeMap, BTreeSet};

use clap::ValueEnum;
use serde::Serialize;
use serde_json::Value;

#[derive(Clone, Debug)]
pub struct OutputConfig {
    pub format: OutputFormat,
    pub max_results: usize,
}

impl Default for OutputConfig {
    fn default() -> Self {
        Self {
            format: OutputFormat::Json,
            max_results: 200,
        }
    }
}

#[derive(Clone, Copy, Debug, Serialize, ValueEnum)]
#[serde(rename_all = "lowercase")]
pub enum OutputFormat {
    Json,
    Markdown,
}

impl OutputConfig {
    pub fn format_lsp(&self, operation: &str, raw: Value) -> String {
        if raw.get("error").is_some() {
            return match self.format {
                OutputFormat::Json => raw.to_string(),
                OutputFormat::Markdown => format_error(&raw),
            };
        }

        let flattened = flatten_locations(raw, self.max_results);
        match self.format {
            OutputFormat::Json => serde_json::to_string(&flattened).unwrap_or_else(|error| {
                serde_json::json!({ "error": error.to_string() }).to_string()
            }),
            OutputFormat::Markdown => format_markdown(operation, &flattened),
        }
    }
}

#[derive(Debug, Serialize)]
struct FlattenedLocations {
    #[serde(skip_serializing_if = "Vec::is_empty")]
    clients: Vec<String>,
    locations: BTreeMap<String, Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    truncated: Option<Truncated>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    errors: BTreeMap<String, String>,
}

#[derive(Debug, Serialize)]
struct Truncated {
    shown: usize,
    total: usize,
}

fn flatten_locations(raw: Value, max_results: usize) -> FlattenedLocations {
    let mut clients = BTreeSet::new();
    let mut errors = BTreeMap::new();
    let mut locations = Vec::new();
    let mut seen = BTreeSet::new();

    for response in raw
        .get("results")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let client = response
            .get("client")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        clients.insert(client.to_owned());

        if let Some(error) = response.get("error").and_then(Value::as_str) {
            errors.insert(client.to_owned(), error.to_owned());
        }

        collect_locations(response.get("result"), &mut locations, &mut seen);
    }

    let total = locations.len();
    locations.truncate(max_results);
    let mut grouped = BTreeMap::<String, Vec<String>>::new();
    for (path, range) in locations {
        grouped.entry(path).or_default().push(range);
    }

    FlattenedLocations {
        clients: clients.into_iter().collect(),
        locations: grouped,
        truncated: (total > max_results).then_some(Truncated {
            shown: max_results,
            total,
        }),
        errors,
    }
}

fn collect_locations(
    value: Option<&Value>,
    locations: &mut Vec<(String, String)>,
    seen: &mut BTreeSet<(String, String)>,
) {
    let Some(value) = value else { return };
    if let Some(items) = value.as_array() {
        for item in items {
            collect_location(item, locations, seen);
        }
    } else {
        collect_location(value, locations, seen);
    }
}

fn collect_location(
    value: &Value,
    locations: &mut Vec<(String, String)>,
    seen: &mut BTreeSet<(String, String)>,
) {
    let path = value
        .get("targetUri")
        .or_else(|| value.get("uri"))
        .and_then(Value::as_str);
    let range = value
        .get("targetSelectionRange")
        .or_else(|| value.get("range"))
        .or_else(|| value.get("targetRange"));
    let (Some(path), Some(range)) = (path, range) else {
        return;
    };
    let Some(range) = compact_range(range) else {
        return;
    };
    let location = (path.to_owned(), range);
    if seen.insert(location.clone()) {
        locations.push(location);
    }
}

fn compact_range(range: &Value) -> Option<String> {
    let start = range.get("start")?;
    let end = range.get("end")?;
    Some(format!(
        "{}:{}-{}:{}",
        start.get("line")?.as_u64()?,
        start.get("character")?.as_u64()?,
        end.get("line")?.as_u64()?,
        end.get("character")?.as_u64()?,
    ))
}

fn format_markdown(operation: &str, result: &FlattenedLocations) -> String {
    let title = operation
        .split('_')
        .map(|part| {
            let mut chars = part.chars();
            chars
                .next()
                .map(|first| first.to_uppercase().collect::<String>() + chars.as_str())
                .unwrap_or_default()
        })
        .collect::<Vec<_>>()
        .join(" ");
    let mut lines = vec![format!("## {title}")];

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
    if !result.errors.is_empty() {
        for (client, error) in &result.errors {
            lines.push(format!("- Error from `{client}`: {error}"));
        }
    }

    lines.join("\n")
}

fn format_error(raw: &Value) -> String {
    let error = &raw["error"];
    let code = error["code"].as_str().unwrap_or("request_failed");
    let message = error["message"].as_str().unwrap_or("Unknown error");
    format!("## Error\n- Code: `{code}`\n- Message: {message}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> Value {
        serde_json::json!({
          "results": [{
            "client": "tsgo",
            "result": [
              { "uri": "/code/a.ts", "range": { "start": { "line": 1, "character": 2 }, "end": { "line": 1, "character": 8 } } },
              { "uri": "/code/a.ts", "range": { "start": { "line": 3, "character": 4 }, "end": { "line": 3, "character": 9 } } },
              { "targetUri": "/code/b.ts", "targetSelectionRange": { "start": { "line": 5, "character": 6 }, "end": { "line": 5, "character": 10 } } }
            ]
          }]
        })
    }

    #[test]
    fn groups_and_truncates_json_locations() {
        let output = OutputConfig {
            format: OutputFormat::Json,
            max_results: 2,
        }
        .format_lsp("references", fixture());
        let output: Value = serde_json::from_str(&output).unwrap();

        assert_eq!(output["clients"], serde_json::json!(["tsgo"]));
        assert_eq!(
            output["locations"]["/code/a.ts"].as_array().unwrap().len(),
            2
        );
        assert_eq!(
            output["truncated"],
            serde_json::json!({ "shown": 2, "total": 3 })
        );
        assert!(output.to_string().len() < fixture().to_string().len());
    }

    #[test]
    fn formats_markdown_locations() {
        let output = OutputConfig {
            format: OutputFormat::Markdown,
            max_results: 2,
        }
        .format_lsp("references", fixture());

        assert!(output.contains("## References"));
        assert!(output.contains("Clients: `tsgo`"));
        assert!(output.contains("`/code/a.ts`: 1:2-1:8, 3:4-3:9"));
        assert!(output.contains("Showing 2 of 3 results"));
    }
}
