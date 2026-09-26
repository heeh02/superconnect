//! Canonical Auth -> Record -> Capability -> Ready composition.
//!
//! Platform adapters execute OS effects, but cannot advance capability negotiation until the exact
//! session/generation has prepared Rust-owned SC-RECORD handles and confirmed that transport routing
//! switched to this owner. Once active, every outer frame is authenticated and classified here.

mod data_plane;
mod record_layer;
mod reducer;
mod types;

pub use reducer::ScSecureConnection;
pub use types::*;
