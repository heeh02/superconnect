use std::mem::size_of;

use crate::collaboration_intent::{
    resolve_intent, IntentCapabilitySet, PeerCapabilityProfile, ProductCapabilityProfile,
};

use super::super::{
    byte_ranges_are_disjoint, checked_byte_range, ffi_guard, pointer_is_aligned,
    versioned_pointer_status, ScStatus, SC_INTERNAL_ERROR, SC_INVALID_ARGUMENT, SC_OK,
};
use super::mapping::{
    decode_draft, decode_peer_profile, decode_product_profile, encode_resolution_error,
    encode_resolved,
};
use super::schema::*;

fn pointer_range<T>(pointer: *const T) -> Option<(usize, usize)> {
    checked_byte_range(pointer.cast::<u8>(), size_of::<T>())
}

unsafe fn all_versioned(statuses: &[ScStatus]) -> ScStatus {
    statuses
        .iter()
        .copied()
        .find(|status| *status != SC_OK)
        .unwrap_or(SC_OK)
}

#[no_mangle]
pub unsafe extern "C" fn sc_collaboration_intent_validate_profile_v1(
    profile: *const ScCollaborationIntentProfileV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let status = versioned_pointer_status(profile);
        if status != SC_OK {
            return status;
        }
        if decode_product_profile(profile.read()).is_none() {
            return SC_INVALID_ARGUMENT;
        }
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_collaboration_intent_validate_draft_v1(
    draft: *const ScCollaborationIntentDraftV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let status = versioned_pointer_status(draft);
        if status != SC_OK {
            return status;
        }
        let Some(draft) = decode_draft(draft.read()) else {
            return SC_INVALID_ARGUMENT;
        };
        let Ok(capabilities) = IntentCapabilitySet::try_from_bits(KNOWN_INTENT_BITS) else {
            return SC_INTERNAL_ERROR;
        };
        let Ok(product) = ProductCapabilityProfile::new(capabilities) else {
            return SC_INTERNAL_ERROR;
        };
        let Ok(peer) = PeerCapabilityProfile::new(capabilities) else {
            return SC_INTERNAL_ERROR;
        };
        if resolve_intent(product, peer, draft).is_err() {
            return SC_INVALID_ARGUMENT;
        }
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_collaboration_intent_resolve_v1(
    product: *const ScCollaborationIntentProfileV1,
    peer: *const ScCollaborationIntentProfileV1,
    draft: *const ScCollaborationIntentDraftV1,
    resolved: *mut ScCollaborationIntentResolvedV1,
    error: *mut ScCollaborationIntentErrorV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if product.is_null()
            || peer.is_null()
            || draft.is_null()
            || resolved.is_null()
            || error.is_null()
            || !pointer_is_aligned(product)
            || !pointer_is_aligned(peer)
            || !pointer_is_aligned(draft)
            || !pointer_is_aligned(resolved)
            || !pointer_is_aligned(error)
        {
            return SC_INVALID_ARGUMENT;
        }
        let Some(product_range) = pointer_range(product) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(peer_range) = pointer_range(peer) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(draft_range) = pointer_range(draft) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(resolved_range) = pointer_range(resolved) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(error_range) = pointer_range(error) else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[
            product_range,
            peer_range,
            draft_range,
            resolved_range,
            error_range,
        ]) {
            return SC_INVALID_ARGUMENT;
        }
        let status = all_versioned(&[
            versioned_pointer_status(product),
            versioned_pointer_status(peer),
            versioned_pointer_status(draft),
            versioned_pointer_status(resolved),
            versioned_pointer_status(error),
        ]);
        if status != SC_OK {
            return status;
        }

        let Some(product) = decode_product_profile(product.read()) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(peer) = decode_peer_profile(peer.read()) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(draft) = decode_draft(draft.read()) else {
            return SC_INVALID_ARGUMENT;
        };
        let resolved_size = (*resolved).struct_size;
        let error_size = (*error).struct_size;
        match resolve_intent(product, peer, draft) {
            Ok(value) => {
                let resolved_value = encode_resolved(Some(value), resolved_size);
                let error_value = encode_resolution_error(None, draft, error_size);
                resolved.write(resolved_value);
                error.write(error_value);
                SC_OK
            }
            Err(reason) => {
                let resolved_value = encode_resolved(None, resolved_size);
                let error_value = encode_resolution_error(Some(reason), draft, error_size);
                resolved.write(resolved_value);
                error.write(error_value);
                SC_COLLABORATION_INTENT_REJECTED
            }
        }
    })
}
