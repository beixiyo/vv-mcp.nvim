//! Neovim 实例注册、存活探测与工作区路由

mod model;
mod registry;
mod resolver;

pub use model::{Instance, InstanceList};
pub use registry::Registry;
pub use resolver::resolve_instance;
