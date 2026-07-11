//! 统一 TCP、Unix Socket 与 Windows Named Pipe 的异步连接接口
//!
//! 连接地址来自实例注册表文件，不可完全信任：TCP 形式仅允许回环主机，
//! 避免恶意注册记录把 socket 指向任意远端主机而产生 SSRF。

use std::{io, pin::Pin};

use tokio::io::{AsyncRead, AsyncWrite};

pub type Reader = Pin<Box<dyn AsyncRead + Send>>;
pub type Writer = Pin<Box<dyn AsyncWrite + Send>>;

pub async fn connect(address: &str) -> io::Result<(Reader, Writer)> {
    if let Some((host, port)) = parse_tcp_address(address) {
        if !is_loopback_host(host) {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                format!("refusing to connect to a non-loopback Neovim address: {address}"),
            ));
        }
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
    Some((normalize_host(host), port.parse().ok()?))
}

/// 仅接受回环主机；`localhost`、`127.0.0.0/8`、`::1` 视为本地，其余一律拒绝
fn is_loopback_host(host: &str) -> bool {
    let host = normalize_host(host);
    host.eq_ignore_ascii_case("localhost")
        || host
            .parse::<std::net::IpAddr>()
            .is_ok_and(|ip| ip.is_loopback())
}

fn normalize_host(host: &str) -> &str {
    host.strip_prefix('[')
        .and_then(|inner| inner.strip_suffix(']'))
        .unwrap_or(host)
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
        assert_eq!(parse_tcp_address("[::1]:7777"), Some(("::1", 7777)));
        assert_eq!(parse_tcp_address("/tmp/nvim.1.0"), None);
        assert_eq!(parse_tcp_address(r"\\.\pipe\nvim.1.0"), None);
    }

    #[test]
    fn accepts_only_loopback_tcp_hosts() {
        assert!(is_loopback_host("127.0.0.1"));
        assert!(is_loopback_host("127.42.0.9"));
        assert!(is_loopback_host("localhost"));
        assert!(is_loopback_host("LocalHost"));
        assert!(is_loopback_host("::1"));
        assert!(is_loopback_host("[::1]"));

        assert!(!is_loopback_host("attacker.example"));
        assert!(!is_loopback_host("10.0.0.5"));
        assert!(!is_loopback_host("0.0.0.0"));
    }

    #[tokio::test]
    async fn refuses_non_loopback_tcp_connections() {
        match connect("attacker.example:6666").await {
            Ok(_) => panic!("must refuse a non-loopback TCP address"),
            Err(error) => assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied),
        }
    }

    #[tokio::test]
    async fn connects_to_bracketed_ipv6_loopback() {
        let listener = match tokio::net::TcpListener::bind("[::1]:0").await {
            Ok(listener) => listener,
            Err(error) if error.kind() == std::io::ErrorKind::AddrNotAvailable => return,
            Err(error) => panic!("failed to bind IPv6 loopback listener: {error}"),
        };
        let port = listener.local_addr().unwrap().port();
        let address = format!("[::1]:{port}");
        let (client, accepted) = tokio::join!(connect(&address), listener.accept());

        assert!(client.is_ok(), "bracketed IPv6 loopback must connect");
        assert!(accepted.is_ok(), "listener must accept the connection");
    }
}
