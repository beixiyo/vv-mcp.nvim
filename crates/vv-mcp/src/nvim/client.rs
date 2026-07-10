use std::{io::Cursor, time::Duration};

use rmpv::Value;
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use thiserror::Error;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use super::transport::{self, Reader, Writer};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(3);
const MAX_RESPONSE_BYTES: usize = 8 * 1024 * 1024;
const MAX_SKIPPED_MESSAGES: usize = 1000;

pub struct NvimClient {
    reader: Reader,
    writer: Writer,
    next_message_id: u64,
    buffered: Vec<u8>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Probe {
    pub pid: u32,
    pub cwd: String,
}

#[derive(Debug, Error)]
pub enum NvimError {
    #[error("failed to connect to Neovim: {0}")]
    Connect(#[source] std::io::Error),
    #[error("Neovim RPC I/O failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("Neovim RPC timed out")]
    Timeout,
    #[error("Neovim RPC returned an error: {0}")]
    Rpc(String),
    #[error("invalid Neovim RPC response: {0}")]
    InvalidResponse(String),
    #[error("Neovim RPC response exceeded {MAX_RESPONSE_BYTES} bytes")]
    ResponseTooLarge,
    #[error("failed to encode or decode MessagePack: {0}")]
    MessagePack(String),
}

impl NvimClient {
    pub async fn connect(address: &str) -> Result<Self, NvimError> {
        let (reader, writer) = tokio::time::timeout(REQUEST_TIMEOUT, transport::connect(address))
            .await
            .map_err(|_| NvimError::Timeout)?
            .map_err(NvimError::Connect)?;

        Ok(Self {
            reader,
            writer,
            next_message_id: 0,
            buffered: Vec::new(),
        })
    }

    pub async fn probe(address: &str) -> Result<Probe, NvimError> {
        let mut client = Self::connect(address).await?;
        client
            .exec_lua(
                "return { pid = vim.fn.getpid(), cwd = vim.fn.getcwd() }",
                Vec::<String>::new(),
            )
            .await
    }

    pub async fn exec_lua<P, R>(&mut self, code: &str, args: P) -> Result<R, NvimError>
    where
        P: Serialize,
        R: DeserializeOwned,
    {
        let args =
            rmpv::ext::to_value(args).map_err(|error| NvimError::MessagePack(error.to_string()))?;
        let value = self
            .request("nvim_exec_lua", vec![Value::from(code), args])
            .await?;
        rmpv::ext::from_value(value).map_err(|error| NvimError::MessagePack(error.to_string()))
    }

    async fn request(&mut self, method: &str, args: Vec<Value>) -> Result<Value, NvimError> {
        self.next_message_id += 1;
        let message_id = self.next_message_id;
        let request = Value::Array(vec![
            Value::from(0),
            Value::from(message_id),
            Value::from(method),
            Value::Array(args),
        ]);
        let mut encoded = Vec::new();
        rmpv::encode::write_value(&mut encoded, &request)
            .map_err(|error| NvimError::MessagePack(error.to_string()))?;

        tokio::time::timeout(REQUEST_TIMEOUT, self.writer.write_all(&encoded))
            .await
            .map_err(|_| NvimError::Timeout)??;
        tokio::time::timeout(REQUEST_TIMEOUT, self.writer.flush())
            .await
            .map_err(|_| NvimError::Timeout)??;

        tokio::time::timeout(REQUEST_TIMEOUT, self.read_response(message_id))
            .await
            .map_err(|_| NvimError::Timeout)?
    }

    async fn read_response(&mut self, expected_id: u64) -> Result<Value, NvimError> {
        let mut skipped = 0;
        loop {
            if let Some(message) = decode_one(&mut self.buffered)? {
                let fields = message
                    .as_array()
                    .ok_or_else(|| NvimError::InvalidResponse("message is not an array".into()))?;
                if fields.len() < 4
                    || fields[0].as_i64() != Some(1)
                    || fields[1].as_u64() != Some(expected_id)
                {
                    skipped += 1;
                    if skipped >= MAX_SKIPPED_MESSAGES {
                        return Err(NvimError::InvalidResponse(
                            "too many unrelated RPC messages".into(),
                        ));
                    }
                    continue;
                }

                if !fields[2].is_nil() {
                    return Err(NvimError::Rpc(fields[2].to_string()));
                }
                return Ok(fields[3].clone());
            }

            let mut chunk = [0_u8; 8192];
            let read = self.reader.read(&mut chunk).await?;
            if read == 0 {
                return Err(NvimError::InvalidResponse(
                    "connection closed before a response arrived".into(),
                ));
            }
            self.buffered.extend_from_slice(&chunk[..read]);
            if self.buffered.len() > MAX_RESPONSE_BYTES {
                return Err(NvimError::ResponseTooLarge);
            }
        }
    }
}

impl NvimError {
    pub fn proves_instance_is_stale(&self) -> bool {
        match self {
            Self::Connect(error) => matches!(
                error.kind(),
                std::io::ErrorKind::NotFound
                    | std::io::ErrorKind::ConnectionRefused
                    | std::io::ErrorKind::ConnectionReset
            ),
            _ => false,
        }
    }
}

fn decode_one(buffer: &mut Vec<u8>) -> Result<Option<Value>, NvimError> {
    if buffer.is_empty() {
        return Ok(None);
    }

    let mut cursor = Cursor::new(buffer.as_slice());
    match rmpv::decode::read_value(&mut cursor) {
        Ok(value) => {
            let consumed = cursor.position() as usize;
            buffer.drain(..consumed);
            Ok(Some(value))
        }
        Err(error) if is_unexpected_eof(&error) => Ok(None),
        Err(error) => Err(NvimError::MessagePack(error.to_string())),
    }
}

fn is_unexpected_eof(error: &rmpv::decode::Error) -> bool {
    use rmpv::decode::Error::{DepthLimitExceeded, InvalidDataRead, InvalidMarkerRead};

    match error {
        InvalidMarkerRead(error) | InvalidDataRead(error) => {
            error.kind() == std::io::ErrorKind::UnexpectedEof
        }
        DepthLimitExceeded => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn waits_for_complete_messagepack_value() {
        let value = Value::Array(vec![
            Value::from(1),
            Value::from(2),
            Value::Nil,
            Value::from("ok"),
        ]);
        let mut encoded = Vec::new();
        rmpv::encode::write_value(&mut encoded, &value).unwrap();
        let tail = encoded.split_off(encoded.len() - 1);

        assert!(decode_one(&mut encoded).unwrap().is_none());
        encoded.extend(tail);
        assert_eq!(decode_one(&mut encoded).unwrap(), Some(value));
        assert!(encoded.is_empty());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn probes_a_real_neovim_socket() {
        let dir = std::env::temp_dir().join(format!("vv-mcp-rpc-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("nvim.sock");
        let mut child = tokio::process::Command::new("nvim")
            .args(["--headless", "--clean", "--listen"])
            .arg(&socket)
            .arg("+sleep 10000m")
            .spawn()
            .unwrap();

        let mut probe = None;
        for _ in 0..50 {
            match NvimClient::probe(socket.to_str().unwrap()).await {
                Ok(result) => {
                    probe = Some(result);
                    break;
                }
                Err(_) => tokio::time::sleep(Duration::from_millis(20)).await,
            }
        }

        let probe = probe.expect("real Neovim socket should accept Msgpack-RPC");
        assert_eq!(probe.pid, child.id().unwrap());
        assert!(!probe.cwd.is_empty());

        child.kill().await.unwrap();
        let _ = child.wait().await;
        let _ = std::fs::remove_dir_all(dir);
    }
}
