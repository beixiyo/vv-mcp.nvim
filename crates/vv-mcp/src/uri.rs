//! 将 CLI/MCP 接收的本地路径或 file URI 转换为原生路径

use std::path::PathBuf;

pub fn native_path(input: &str) -> Result<PathBuf, String> {
    let Some(encoded) = input.strip_prefix("file://") else {
        return Ok(PathBuf::from(input));
    };
    let encoded = if let Some(path) = encoded.strip_prefix("localhost") {
        path
    } else if encoded.starts_with('/') || encoded.as_bytes().get(1) == Some(&b':') {
        encoded
    } else {
        return Err(format!("remote file URI is not supported: {input}"));
    };
    let decoded = decode_percent(encoded)?;

    #[cfg(windows)]
    let decoded = decoded
        .strip_prefix('/')
        .filter(|path| path.as_bytes().get(1) == Some(&b':'))
        .unwrap_or(&decoded)
        .to_owned();

    Ok(PathBuf::from(decoded))
}

fn decode_percent(input: &str) -> Result<String, String> {
    let bytes = input.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;

    while index < bytes.len() {
        if bytes[index] != b'%' {
            decoded.push(bytes[index]);
            index += 1;
            continue;
        }
        let hex = bytes
            .get(index + 1..index + 3)
            .ok_or_else(|| format!("invalid percent encoding in file URI: {input}"))?;
        let hex = std::str::from_utf8(hex).map_err(|error| error.to_string())?;
        let byte = u8::from_str_radix(hex, 16)
            .map_err(|_| format!("invalid percent encoding in file URI: {input}"))?;
        decoded.push(byte);
        index += 3;
    }

    String::from_utf8(decoded).map_err(|error| format!("file URI path is not UTF-8: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_percent_encoded_file_uri() {
        assert_eq!(
            native_path("file:///tmp/my%20project/main.ts").unwrap(),
            PathBuf::from("/tmp/my project/main.ts")
        );
        assert!(native_path("file://server/share/main.ts").is_err());
    }
}
