mod code_actions;
mod config;
mod diagnostics;
mod documentation;
mod highlights;
mod locations;
mod markdown;
mod model;
mod rename;
mod symbols;

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

        match operation {
            "code_actions"
            | "code_action_preview"
            | "file_quickfix_preview"
            | "code_action_apply" => {
                code_actions::format(operation, raw, self.max_results, self.format)
            }
            "document_highlight" => highlights::format(raw, self.max_results, self.format),
            "prepare_rename" | "rename_preview" | "rename_apply" => {
                rename::format(operation, raw, self.max_results, self.format)
            }
            "diagnostics" | "workspace_diagnostics" => {
                diagnostics::format(operation, raw, self.max_results, self.format)
            }
            "hover" | "signature_help" => {
                documentation::format(operation, raw, self.max_results, self.format)
            }
            "document_symbols" | "workspace_symbols" => {
                symbols::format(operation, raw, self.max_results, self.format)
            }
            _ => {
                let flattened = locations::flatten(raw, self.max_results);
                match self.format {
                    OutputFormat::Json => to_json(&flattened),
                    OutputFormat::Markdown => markdown::format_locations(operation, &flattened),
                }
            }
        }
    }
}

fn to_json(value: &impl serde::Serialize) -> String {
    serde_json::to_string(value)
        .unwrap_or_else(|error| serde_json::json!({ "error": error.to_string() }).to_string())
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

    #[test]
    fn compacts_signature_parameters() {
        let raw = serde_json::json!({
          "results": [{
            "client": "tsgo",
            "result": {
              "activeSignature": 0,
              "activeParameter": 1,
              "signatures": [{
                "label": "create(name: string, age: number)",
                "parameters": [
                  { "label": "name: string", "documentation": "User name" },
                  { "label": [21, 32], "documentation": { "kind": "markdown", "value": "User age" } }
                ]
              }]
            }
          }]
        });
        let output = OutputConfig::default().format_lsp("signature_help", raw);
        let output: Value = serde_json::from_str(&output).unwrap();

        assert_eq!(output["items"][0]["activeParameter"], 2);
        assert_eq!(output["items"][0]["parameters"][0]["label"], "name: string");
        assert_eq!(
            output["items"][0]["parameters"][1]["documentation"],
            "User age"
        );
        assert!(output.get("truncated").is_none());
    }

    #[test]
    fn markdown_signature_keeps_active_parameter_and_parameter_docs() {
        let raw = serde_json::json!({
          "results": [
            { "client": "dprint", "result": null },
            {
              "client": "tsgo",
              "result": {
                "activeSignature": 0,
                "signatures": [{
                  "label": "create(name: string, age: number)",
                  "activeParameter": 1,
                  "parameters": [
                    { "label": "name: string", "documentation": "User name" },
                    { "label": "age: number", "documentation": "User age" }
                  ]
                }]
              }
            }
          ]
        });
        let output = OutputConfig {
            format: OutputFormat::Markdown,
            max_results: 2,
        }
        .format_lsp("signature_help", raw);

        assert!(output.contains("Clients: `tsgo`"));
        assert!(!output.contains("dprint"));
        assert!(output.contains("Active parameter: 2 (`age: number`)"));
        assert!(output.contains("Parameter 1: `name: string`: User name"));
        assert!(output.contains("Parameter 2: `age: number`: User age"));
    }

    #[test]
    fn flattens_and_caps_document_symbols() {
        let raw = serde_json::json!({
          "path": "/code/a.ts",
          "results": [{
            "client": "tsgo",
            "result": [{
              "name": "User",
              "kind": 5,
              "selectionRange": { "start": { "line": 1, "character": 1 }, "end": { "line": 1, "character": 5 } },
              "children": [{
                "name": "login",
                "kind": 6,
                "selectionRange": { "start": { "line": 2, "character": 3 }, "end": { "line": 2, "character": 8 } }
              }]
            }]
          }]
        });
        let output = OutputConfig {
            format: OutputFormat::Json,
            max_results: 1,
        }
        .format_lsp("document_symbols", raw);
        let output: Value = serde_json::from_str(&output).unwrap();

        assert_eq!(output["symbols"]["/code/a.ts"][0]["kind"], "Class");
        assert_eq!(
            output["truncated"],
            serde_json::json!({ "shown": 1, "total": 2 })
        );
    }

    #[test]
    fn groups_deduplicates_and_caps_diagnostics() {
        let diagnostic = serde_json::json!({
          "path": "/code/a.ts",
          "range": { "start": { "line": 2, "character": 3 }, "end": { "line": 2, "character": 8 } },
          "severity": 1,
          "message": "Cannot find name 'foo'",
          "source": "tsgo",
          "code": 2304,
        });
        let raw = serde_json::json!({
          "diagnostics": [diagnostic, diagnostic, {
            "path": "/code/b.ts",
            "range": { "start": { "line": 4, "character": 1 }, "end": { "line": 4, "character": 2 } },
            "severity": 2,
            "message": "Unused value"
          }]
        });
        let output = OutputConfig {
            format: OutputFormat::Json,
            max_results: 1,
        }
        .format_lsp("workspace_diagnostics", raw);
        let output: Value = serde_json::from_str(&output).unwrap();

        assert_eq!(output["diagnostics"]["/code/a.ts"][0]["severity"], "error");
        assert_eq!(output["diagnostics"]["/code/a.ts"][0]["code"], "2304");
        assert_eq!(
            output["truncated"],
            serde_json::json!({ "shown": 1, "total": 2 })
        );
    }

    #[test]
    fn caps_rename_preview_without_truncating_edit_totals() {
        let raw = serde_json::json!({
          "renameId": "rename-1",
          "client": "tsgo",
          "newName": "nextName",
          "filesChanged": 2,
          "editsCount": 3,
          "expiresAt": 123,
          "changes": {
            "/code/a.ts": [
              { "start": { "line": 1, "character": 2 }, "end": { "line": 1, "character": 5 } },
              { "start": { "line": 4, "character": 2 }, "end": { "line": 4, "character": 5 } }
            ],
            "/code/b.ts": [
              { "start": { "line": 2, "character": 1 }, "end": { "line": 2, "character": 4 } }
            ]
          }
        });
        let output = OutputConfig {
            format: OutputFormat::Json,
            max_results: 1,
        }
        .format_lsp("rename_preview", raw);
        let output: Value = serde_json::from_str(&output).unwrap();

        assert_eq!(output["editsCount"], 3);
        assert_eq!(
            output["truncated"],
            serde_json::json!({ "shown": 1, "total": 3 })
        );
        assert_eq!(output["changes"]["/code/a.ts"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn formats_and_caps_document_highlights() {
        let raw = serde_json::json!({
          "path": "/code/a.ts",
          "results": [{
            "client": "tsgo",
            "result": [
              { "range": { "start": { "line": 2, "character": 3 }, "end": { "line": 2, "character": 6 } }, "kind": 3 },
              { "range": { "start": { "line": 4, "character": 1 }, "end": { "line": 4, "character": 4 } }, "kind": 2 }
            ]
          }]
        });
        let output = OutputConfig {
            format: OutputFormat::Json,
            max_results: 1,
        }
        .format_lsp("document_highlight", raw);
        let output: Value = serde_json::from_str(&output).unwrap();

        assert_eq!(output["clients"], serde_json::json!(["tsgo"]));
        assert_eq!(output["highlights"][0]["kind"], "write");
        assert_eq!(output["highlights"][0]["range"], "2:3-2:6");
        assert_eq!(
            output["truncated"],
            serde_json::json!({ "shown": 1, "total": 2 })
        );
    }

    #[test]
    fn caps_code_action_preview_without_losing_edit_totals() {
        let raw = serde_json::json!({
          "actionId": "action-1",
          "title": "Fix issue",
          "filesChanged": 1,
          "editsCount": 2,
          "expiresAt": 123,
          "changes": {
            "/code/a.ts": [
              { "start": { "line": 1, "character": 1 }, "end": { "line": 1, "character": 3 } },
              { "start": { "line": 3, "character": 1 }, "end": { "line": 3, "character": 3 } }
            ]
          }
        });
        let output = OutputConfig {
            format: OutputFormat::Json,
            max_results: 1,
        }
        .format_lsp("code_action_preview", raw);
        let output: Value = serde_json::from_str(&output).unwrap();

        assert_eq!(output["editsCount"], 2);
        assert_eq!(output["changes"]["/code/a.ts"].as_array().unwrap().len(), 1);
        assert_eq!(
            output["truncated"],
            serde_json::json!({ "shown": 1, "total": 2 })
        );
    }
}
