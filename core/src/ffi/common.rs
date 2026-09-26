use std::mem::{align_of, size_of};
use std::panic::{catch_unwind, AssertUnwindSafe};

include!(concat!(env!("OUT_DIR"), "/abi_identity.rs"));

pub const SC_API_VERSION_V1: u32 = 1;
pub const SC_INPUT_RECORD_V1_SIZE: usize = crate::wire::input::INPUT_RECORD_SIZE;
pub const SC_INPUT_SEQUENCED_RECORD_V1_SIZE: usize =
    crate::wire::input::INPUT_SEQUENCED_RECORD_SIZE;
pub const SC_OK: i32 = 0;
pub const SC_INVALID_ARGUMENT: i32 = 1;
pub const SC_FRAME_TOO_LARGE: i32 = 2;
pub const SC_CALLBACK_ABORTED: i32 = 3;
pub const SC_INTERNAL_ERROR: i32 = 4;
pub const SC_BUFFER_TOO_SMALL: i32 = 5;
pub const SC_NO_FRAME: i32 = 6;
pub const SC_STALE_VIEW: i32 = 7;
pub const SC_UNSUPPORTED_VERSION: i32 = 8;
pub const SC_DECODER_POISONED: i32 = 9;

pub type ScStatus = i32;

pub(super) fn ffi_guard<T>(fallback: T, body: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(fallback)
}

pub(super) fn pointer_is_aligned<T>(pointer: *const T) -> bool {
    (pointer as usize).is_multiple_of(align_of::<T>())
}

pub(super) fn checked_byte_range(pointer: *const u8, length: usize) -> Option<(usize, usize)> {
    if pointer.is_null() && length != 0 {
        return None;
    }
    let start = pointer as usize;
    Some((start, start.checked_add(length)?))
}

fn byte_ranges_overlap(left: (usize, usize), right: (usize, usize)) -> bool {
    left.0 < right.1 && right.0 < left.1
}

pub(super) fn byte_ranges_are_disjoint(ranges: &[(usize, usize)]) -> bool {
    ranges.iter().enumerate().all(|(index, left)| {
        ranges[index + 1..]
            .iter()
            .all(|right| !byte_ranges_overlap(*left, *right))
    })
}

pub(super) unsafe fn versioned_pointer_status<T>(pointer: *const T) -> ScStatus {
    if pointer.is_null() || !pointer_is_aligned(pointer) {
        return SC_INVALID_ARGUMENT;
    }
    if checked_byte_range(pointer.cast::<u8>(), size_of::<T>()).is_none() {
        return SC_INVALID_ARGUMENT;
    }
    let bytes = pointer.cast::<u8>();
    let struct_size = bytes.cast::<u32>().read_unaligned();
    if struct_size < size_of::<T>() as u32 {
        SC_INVALID_ARGUMENT
    } else {
        let api_version = bytes.add(size_of::<u32>()).cast::<u32>().read_unaligned();
        if api_version == SC_API_VERSION_V1 {
            SC_OK
        } else {
            SC_UNSUPPORTED_VERSION
        }
    }
}
