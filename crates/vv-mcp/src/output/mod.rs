mod config;
mod locations;
mod markdown;
mod model;

use serde_json::Value;

pub use config::{OutputConfig, OutputFormat};

impl OutputConfig {
    pub fn format_lsp(&self, operation: &str, raw: Value) -> String {
        if raw.get("error").is_some() {
            return match self.format {
                OutputFormat::Json => raw.to_string(),
                OutputFormat::Markdown => markdown::format_error(&raw),
            };
        }

        let flattened = locations::flatten(raw, self.max_results);
        match self.format {
            OutputFormat::Json => serde_json::to_string(&flattened).unwrap_or_else(|error| {
                serde_json::json!({ "error": error.to_string() }).to_string()
            }),
            OutputFormat::Markdown => markdown::format_locations(operation, &flattened),
        }
    }
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
