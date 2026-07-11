//! 与 Neovim Msgpack-RPC 通信的客户端和跨平台传输层

mod client;
mod transport;

pub(crate) use client::{NvimClient, NvimError};
