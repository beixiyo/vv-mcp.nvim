//! 统一 TCP、Unix Socket 与 Windows Named Pipe 的异步连接接口

use std::{io, pin::Pin};

use tokio::io::{AsyncRead, AsyncWrite};

pub type Reader = Pin<Box<dyn AsyncRead + Send>>;
pub type Writer = Pin<Box<dyn AsyncWrite + Send>>;

pub async fn connect(address: &str) -> io::Result<(Reader, Writer)> {
    if let Some((host, port)) = parse_tcp_address(address) {
        let stream = tokio::net::TcpStream::connect((host, port)).await?;
        let (reader, writer) = tokio::io::split(stream);
        return Ok((Box::pin(reader), Box::pin(writer)));
    }

    connect_local(address).await
}

#[cfg(unix)]
async fn connect_local(address: &str) -> io::Result<(Reader, Writer)> {
    let stream = tokio::net::UnixStream::connect(address).await?;
    let (reader, writer) = tokio::io::split(stream);
    Ok((Box::pin(reader), Box::pin(writer)))
}

#[cfg(windows)]
async fn connect_local(address: &str) -> io::Result<(Reader, Writer)> {
    use tokio::net::windows::named_pipe::ClientOptions;

    let stream = ClientOptions::new().open(address)?;
    let (reader, writer) = tokio::io::split(stream);
    Ok((Box::pin(reader), Box::pin(writer)))
}

fn parse_tcp_address(address: &str) -> Option<(&str, u16)> {
    if address.starts_with('/') || address.starts_with(r"\\.\pipe\") {
        return None;
    }

    let (host, port) = address.rsplit_once(':')?;
    Some((host, port.parse().ok()?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_tcp_without_mistaking_local_sockets() {
        assert_eq!(
            parse_tcp_address("127.0.0.1:7777"),
            Some(("127.0.0.1", 7777))
        );
        assert_eq!(parse_tcp_address("/tmp/nvim.1.0"), None);
        assert_eq!(parse_tcp_address(r"\\.\pipe\nvim.1.0"), None);
    }
}
