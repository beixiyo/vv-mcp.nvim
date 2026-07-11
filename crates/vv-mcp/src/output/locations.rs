//! 将定义、引用等 Location 结果去重、分组并截断

use std::collections::{BTreeMap, BTreeSet};

use serde_json::Value;

use super::model::{FlattenedLocations, Truncated};

pub(super) fn flatten(raw: Value, max_results: usize) -> FlattenedLocations {
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
        if let Some(error) = response.get("error").and_then(Value::as_str) {
            errors.insert(client.to_owned(), error.to_owned());
        }

        let previous_len = locations.len();
        collect_locations(response.get("result"), &mut locations, &mut seen);
        if locations.len() > previous_len {
            clients.insert(client.to_owned());
        }
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
