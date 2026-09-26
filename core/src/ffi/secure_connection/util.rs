use std::mem::size_of;

use crate::secure_connection::SecureConnectionEffects;

use super::super::checked_byte_range;
use super::types::ScSecureConnectionV1;

pub(super) fn handle_range(handle: *const ScSecureConnectionV1) -> Option<(usize, usize)> {
    checked_byte_range(handle.cast(), size_of::<ScSecureConnectionV1>())
}

pub(super) fn outputs_are_drained(handle: &ScSecureConnectionV1) -> bool {
    handle.effects.is_empty()
        && handle.inbound.is_empty()
        && handle.borrowed_inbound_generation.is_none()
}

pub(super) fn queue_effects(handle: &mut ScSecureConnectionV1, effects: SecureConnectionEffects) {
    debug_assert!(handle.effects.is_empty());
    debug_assert!(effects.len() <= crate::secure_connection::MAX_SECURE_CONNECTION_EFFECTS);
    handle.effects.extend(effects.iter().copied());
}

pub(super) fn queue_pending_data_effects(handle: &mut ScSecureConnectionV1) {
    let effects = handle.inner.take_pending_effects();
    if !effects.is_empty() {
        queue_effects(handle, effects);
    }
}
