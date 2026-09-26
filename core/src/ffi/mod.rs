#![allow(clippy::missing_safety_doc)]

mod admission;
mod auth_v1;
mod auth_wire;
mod capability;
mod capability_intent_v2;
mod collaboration_intent;
mod common;
mod control_envelope;
mod frame;
mod input;
mod input_ownership;
mod media_recovery;
mod receiver_progress;
mod record_v1;
mod secure_connection;
mod session;
mod types;
mod video_meta;

pub use admission::*;
pub use auth_v1::*;
pub use auth_wire::*;
pub use capability::*;
pub use capability_intent_v2::*;
pub use collaboration_intent::*;
pub use common::*;
pub use control_envelope::*;
pub use frame::*;
pub use input::*;
pub use input_ownership::*;
pub use media_recovery::*;
pub use receiver_progress::*;
pub use record_v1::*;
pub use secure_connection::*;
pub use session::*;
pub use types::*;
pub use video_meta::*;

use common::{
    byte_ranges_are_disjoint, checked_byte_range, ffi_guard, pointer_is_aligned,
    versioned_pointer_status,
};

#[no_mangle]
pub extern "C" fn sc_core_abi_version_v1() -> u32 {
    ffi_guard(0, || SC_API_VERSION_V1)
}

#[no_mangle]
pub extern "C" fn sc_core_abi_identity_v1() -> u64 {
    ffi_guard(0, || SC_CORE_CANONICAL_ABI_ID_V1)
}

#[cfg(any(debug_assertions, feature = "ffi-test-hooks"))]
#[no_mangle]
pub extern "C" fn sc_core_test_panic_v1() -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        panic!("deliberate FFI boundary panic")
    })
}
