//! Receiver progress wire format and shared strict parsing, without unused diagnostics reducers.
pub(crate) mod wire;
pub use wire::*;
pub use crate::session_generation::SessionGeneration;
