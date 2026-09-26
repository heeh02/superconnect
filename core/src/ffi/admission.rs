use std::mem::{align_of, size_of};
use std::ptr;

use crate::admission::{
    AdmissionEffect, AdmissionEvent, OwnerId, ScAdmission as CoreAdmission, TimerKind, TimerToken,
    MAX_PENDING_LIMIT,
};

use super::{
    byte_ranges_are_disjoint, checked_byte_range, ffi_guard, pointer_is_aligned,
    versioned_pointer_status, ScStatus, SC_API_VERSION_V1, SC_BUFFER_TOO_SMALL, SC_INTERNAL_ERROR,
    SC_INVALID_ARGUMENT, SC_OK,
};

pub const SC_ADMISSION_EVENT_ACCEPTED: u32 = 1;
pub const SC_ADMISSION_EVENT_PAIRING_PROMPT: u32 = 2;
pub const SC_ADMISSION_EVENT_AUTHENTICATED: u32 = 3;
pub const SC_ADMISSION_EVENT_TIMED_OUT: u32 = 4;
pub const SC_ADMISSION_EVENT_CLOSED: u32 = 5;

pub const SC_ADMISSION_EFFECT_ARM_TIMER: u32 = 1;
pub const SC_ADMISSION_EFFECT_CANCEL_TIMER: u32 = 2;
pub const SC_ADMISSION_EFFECT_CLAIM: u32 = 3;
pub const SC_ADMISSION_EFFECT_REJECT_BUSY: u32 = 4;
pub const SC_ADMISSION_EFFECT_REJECT_CAPACITY: u32 = 5;
pub const SC_ADMISSION_EFFECT_CLOSE: u32 = 6;
pub const SC_ADMISSION_EFFECT_PENDING_RELEASED: u32 = 7;
pub const SC_ADMISSION_EFFECT_ACTIVE_RELEASED: u32 = 8;

pub const SC_ADMISSION_TIMER_NONE: u32 = 0;
pub const SC_ADMISSION_TIMER_AUTHENTICATION: u32 = 1;
pub const SC_ADMISSION_TIMER_PAIRING: u32 = 2;

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScAdmissionConfigV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub max_pending: u32,
    pub reserved: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScAdmissionEventV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub kind: u32,
    pub reserved: u32,
    pub owner: u64,
    pub token: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScAdmissionEffectV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub kind: u32,
    pub timer_kind: u32,
    pub owner: u64,
    pub token: u64,
    pub timeout_ms: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScAdmissionSnapshotV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub active_owner: u64,
    pub pending_count: u32,
    pub max_pending: u32,
    pub reserved: [u32; 2],
}

#[repr(C)]
pub struct ScAdmissionV1 {
    inner: CoreAdmission,
}

fn admission_event(input: ScAdmissionEventV1) -> Result<AdmissionEvent, ScStatus> {
    if input.reserved != 0 || input.owner == 0 {
        return Err(SC_INVALID_ARGUMENT);
    }
    let owner = OwnerId::new(input.owner);
    match input.kind {
        SC_ADMISSION_EVENT_ACCEPTED if input.token == 0 => Ok(AdmissionEvent::Accepted { owner }),
        SC_ADMISSION_EVENT_PAIRING_PROMPT if input.token == 0 => {
            Ok(AdmissionEvent::PairingPrompt { owner })
        }
        SC_ADMISSION_EVENT_AUTHENTICATED if input.token == 0 => {
            Ok(AdmissionEvent::Authenticated { owner })
        }
        SC_ADMISSION_EVENT_TIMED_OUT if input.token != 0 => Ok(AdmissionEvent::TimedOut {
            owner,
            token: TimerToken::new(input.token),
        }),
        SC_ADMISSION_EVENT_CLOSED if input.token == 0 => Ok(AdmissionEvent::Closed { owner }),
        _ => Err(SC_INVALID_ARGUMENT),
    }
}

fn admission_effect(effect: AdmissionEffect, struct_size: u32) -> ScAdmissionEffectV1 {
    let mut output = ScAdmissionEffectV1 {
        struct_size,
        api_version: SC_API_VERSION_V1,
        kind: 0,
        timer_kind: SC_ADMISSION_TIMER_NONE,
        owner: 0,
        token: 0,
        timeout_ms: 0,
    };
    match effect {
        AdmissionEffect::ArmTimer {
            owner,
            token,
            kind,
            timeout_ms,
        } => {
            output.kind = SC_ADMISSION_EFFECT_ARM_TIMER;
            output.timer_kind = match kind {
                TimerKind::Authentication => SC_ADMISSION_TIMER_AUTHENTICATION,
                TimerKind::Pairing => SC_ADMISSION_TIMER_PAIRING,
            };
            output.owner = owner.get();
            output.token = token.get();
            output.timeout_ms = timeout_ms;
        }
        AdmissionEffect::CancelTimer { owner, token } => {
            output.kind = SC_ADMISSION_EFFECT_CANCEL_TIMER;
            output.owner = owner.get();
            output.token = token.get();
        }
        AdmissionEffect::Claim { owner } => {
            output.kind = SC_ADMISSION_EFFECT_CLAIM;
            output.owner = owner.get();
        }
        AdmissionEffect::RejectBusy { owner } => {
            output.kind = SC_ADMISSION_EFFECT_REJECT_BUSY;
            output.owner = owner.get();
        }
        AdmissionEffect::RejectCapacity { owner } => {
            output.kind = SC_ADMISSION_EFFECT_REJECT_CAPACITY;
            output.owner = owner.get();
        }
        AdmissionEffect::Close { owner } => {
            output.kind = SC_ADMISSION_EFFECT_CLOSE;
            output.owner = owner.get();
        }
        AdmissionEffect::PendingReleased { owner } => {
            output.kind = SC_ADMISSION_EFFECT_PENDING_RELEASED;
            output.owner = owner.get();
        }
        AdmissionEffect::ActiveReleased { owner } => {
            output.kind = SC_ADMISSION_EFFECT_ACTIVE_RELEASED;
            output.owner = owner.get();
        }
    }
    output
}

#[no_mangle]
pub unsafe extern "C" fn sc_admission_new_v1(
    config: *const ScAdmissionConfigV1,
    output: *mut *mut ScAdmissionV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if output.is_null() || !pointer_is_aligned(output) {
            return SC_INVALID_ARGUMENT;
        }
        let status = versioned_pointer_status(config);
        if status != SC_OK {
            return status;
        }
        let Some(config_range) =
            checked_byte_range(config.cast::<u8>(), size_of::<ScAdmissionConfigV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) =
            checked_byte_range(output.cast::<u8>(), size_of::<*mut ScAdmissionV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[config_range, output_range]) {
            return SC_INVALID_ARGUMENT;
        }
        output.write(ptr::null_mut());
        let config = config.read();
        if config.reserved != 0
            || config.max_pending == 0
            || config.max_pending as usize > MAX_PENDING_LIMIT
        {
            return SC_INVALID_ARGUMENT;
        }
        let Ok(inner) = CoreAdmission::new(config.max_pending as usize) else {
            return SC_INVALID_ARGUMENT;
        };
        output.write(Box::into_raw(Box::new(ScAdmissionV1 { inner })));
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_admission_free_v1(admission: *mut ScAdmissionV1) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if admission.is_null() {
            return SC_OK;
        }
        if !pointer_is_aligned(admission) {
            return SC_INVALID_ARGUMENT;
        }
        drop(Box::from_raw(admission));
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_admission_apply_v1(
    admission: *mut ScAdmissionV1,
    event: *const ScAdmissionEventV1,
    effects: *mut ScAdmissionEffectV1,
    effect_capacity: usize,
    effect_stride: usize,
    written: *mut usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if admission.is_null()
            || !pointer_is_aligned(admission)
            || written.is_null()
            || !pointer_is_aligned(written)
            || needed.is_null()
            || !pointer_is_aligned(needed)
            || effect_stride < size_of::<ScAdmissionEffectV1>()
            || effect_stride > u32::MAX as usize
            || !effect_stride.is_multiple_of(align_of::<ScAdmissionEffectV1>())
            || (effects.is_null() && effect_capacity != 0)
            || (!effects.is_null() && !pointer_is_aligned(effects))
        {
            return SC_INVALID_ARGUMENT;
        }
        let Some(effect_bytes) = effect_capacity.checked_mul(effect_stride) else {
            return SC_INVALID_ARGUMENT;
        };
        let status = versioned_pointer_status(event);
        if status != SC_OK {
            return status;
        }
        let Some(admission_range) =
            checked_byte_range(admission.cast::<u8>(), size_of::<ScAdmissionV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(event_range) =
            checked_byte_range(event.cast::<u8>(), size_of::<ScAdmissionEventV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(effects_range) = checked_byte_range(effects.cast::<u8>(), effect_bytes) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(written_range) = checked_byte_range(written.cast::<u8>(), size_of::<usize>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(needed_range) = checked_byte_range(needed.cast::<u8>(), size_of::<usize>()) else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[
            admission_range,
            event_range,
            effects_range,
            written_range,
            needed_range,
        ]) {
            return SC_INVALID_ARGUMENT;
        }
        written.write(0);
        needed.write(0);
        let event = match admission_event(event.read()) {
            Ok(event) => event,
            Err(status) => return status,
        };
        let admission = &mut *admission;
        let (staged, projected) = admission.inner.stage_apply(event);
        needed.write(projected.len());
        if effect_capacity < projected.len() {
            return SC_BUFFER_TOO_SMALL;
        }
        for (index, effect) in projected.into_iter().enumerate() {
            effects
                .cast::<u8>()
                .add(index * effect_stride)
                .cast::<ScAdmissionEffectV1>()
                .write(admission_effect(effect, effect_stride as u32));
        }
        admission.inner = staged;
        written.write(needed.read());
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_admission_snapshot_v1(
    admission: *const ScAdmissionV1,
    output: *mut ScAdmissionSnapshotV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if admission.is_null() || !pointer_is_aligned(admission) {
            return SC_INVALID_ARGUMENT;
        }
        let status = versioned_pointer_status(output);
        if status != SC_OK {
            return status;
        }
        let Some(admission_range) =
            checked_byte_range(admission.cast::<u8>(), size_of::<ScAdmissionV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) =
            checked_byte_range(output.cast::<u8>(), size_of::<ScAdmissionSnapshotV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[admission_range, output_range]) {
            return SC_INVALID_ARGUMENT;
        }
        let struct_size = output.cast::<u32>().read_unaligned();
        let admission = &*admission;
        output.write(ScAdmissionSnapshotV1 {
            struct_size,
            api_version: SC_API_VERSION_V1,
            active_owner: admission.inner.active_owner().map_or(0, OwnerId::get),
            pending_count: admission.inner.pending_len() as u32,
            max_pending: admission.inner.max_pending() as u32,
            reserved: [0; 2],
        });
        SC_OK
    })
}
