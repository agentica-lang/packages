//! The C API of `agentica_native.h` (version 1.3), as it is: the layouts of the tables and the opaque values. The
//! safe types of the crate are built on it; a module never needs it directly.

#![allow(non_camel_case_types)]

use core::ffi::{c_char, c_int, c_uint, c_void};

/// `AN_API_MAJOR` and `AN_API_MINOR` of the header these layouts copy.
pub const AN_API_MAJOR: u32 = 1;
pub const AN_API_MINOR: u32 = 3;

/// `AN_SHORT` and `AN_DIRTY`, the modes of `an_function.flags`.
pub const AN_SHORT: c_uint = 0;
pub const AN_DIRTY: c_uint = 1;

/// `AN_STRUCT` and `AN_ENUM`, the kinds of `an_type.kind`.
pub const AN_STRUCT: c_int = 0;
pub const AN_ENUM: c_int = 1;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct an_term {
    pub opaque: [u64; 2],
}

/// The env of one call. Opaque: its first field is the `an_api` pointer, which only the VM reads.
#[repr(C)]
pub struct an_env {
    _private: [u8; 0],
}

#[repr(C)]
pub struct an_list_builder {
    pub opaque: [u64; 8],
}

#[repr(C)]
pub struct an_list_cursor {
    pub opaque: [u64; 8],
}

#[repr(C)]
pub struct an_map_cursor {
    pub opaque: [u64; 8],
}

pub type an_fn = unsafe extern "C" fn(env: *mut an_env, argc: c_int, argv: *const an_term) -> an_term;

#[repr(C)]
pub struct an_function {
    pub name: *const c_char,
    pub signature: *const c_char,
    pub fn_: an_fn,
    pub flags: c_uint,
}

#[repr(C)]
pub struct an_type {
    pub name: *const c_char,
    pub kind: c_int,
    pub shape: *const c_char,
}

#[repr(C)]
pub struct an_resource_type {
    pub name: *const c_char,
    pub size: usize,
    pub free: Option<unsafe extern "C" fn(state: *mut c_void)>,
}

#[repr(C)]
pub struct an_module {
    pub major: u32,
    pub minor: u32,
    pub size: u32,
    pub name: *const c_char,
    pub load: Option<unsafe extern "C" fn() -> *const c_char>,
    pub functions: *const an_function,
    pub function_count: u32,
    pub types: *const an_type,
    pub type_count: u32,
    pub resources: *const an_resource_type,
    pub resource_count: u32,
}

type E = *mut an_env;
type T = an_term;

#[repr(C)]
pub struct an_api {
    pub major: u32,
    pub minor: u32,
    pub size: u32,
    pub make_int: unsafe extern "C" fn(E, i64) -> T,
    pub get_int: unsafe extern "C" fn(E, T, *mut i64) -> bool,
    pub make_float: unsafe extern "C" fn(E, f64) -> T,
    pub get_float: unsafe extern "C" fn(E, T, *mut f64) -> bool,
    pub make_bool: unsafe extern "C" fn(E, bool) -> T,
    pub get_bool: unsafe extern "C" fn(E, T, *mut bool) -> bool,
    pub make_void: unsafe extern "C" fn(E) -> T,
    pub make_string: unsafe extern "C" fn(E, *const c_char, usize) -> T,
    pub get_string: unsafe extern "C" fn(E, T, *mut *const c_char, *mut usize) -> bool,
    pub make_bytes: unsafe extern "C" fn(E, *const c_void, usize) -> T,
    pub bytes_fill: unsafe extern "C" fn(E, usize, *mut *mut u8) -> T,
    pub get_bytes: unsafe extern "C" fn(E, T, *mut *const u8, *mut usize) -> bool,
    pub make_list: unsafe extern "C" fn(E, *const T, usize) -> T,
    pub list_begin: unsafe extern "C" fn(E, *mut an_list_builder, usize),
    pub list_push: unsafe extern "C" fn(E, *mut an_list_builder, T),
    pub list_end: unsafe extern "C" fn(E, *mut an_list_builder) -> T,
    pub list_cursor: unsafe extern "C" fn(E, T, *mut an_list_cursor, *mut usize) -> bool,
    pub list_next: unsafe extern "C" fn(E, *mut an_list_cursor, *mut T) -> bool,
    pub map_from: unsafe extern "C" fn(E, *const T, *const T, usize) -> T,
    pub map_put: unsafe extern "C" fn(E, T, T, T) -> T,
    pub map_get: unsafe extern "C" fn(E, T, T, *mut T) -> bool,
    pub map_cursor: unsafe extern "C" fn(E, T, *mut an_map_cursor, *mut usize) -> bool,
    pub map_next: unsafe extern "C" fn(E, *mut an_map_cursor, *mut T, *mut T) -> bool,
    pub make_none: unsafe extern "C" fn(E) -> T,
    pub make_some: unsafe extern "C" fn(E, T) -> T,
    pub get_optional: unsafe extern "C" fn(E, T, *mut bool, *mut T) -> bool,
    pub make_ok: unsafe extern "C" fn(E, T) -> T,
    pub make_error: unsafe extern "C" fn(E, *const c_char, usize) -> T,
    pub get_result: unsafe extern "C" fn(E, T, *mut bool, *mut T) -> bool,
    pub raise: unsafe extern "C" fn(E, *const c_char) -> T,
    pub badarg: unsafe extern "C" fn(E, c_int) -> T,
    pub make_struct: unsafe extern "C" fn(E, u32, *const T) -> T,
    pub get_field: unsafe extern "C" fn(E, T, u32, u32, *mut T) -> bool,
    pub make_enum: unsafe extern "C" fn(E, u32, u32, *const T) -> T,
    pub get_variant: unsafe extern "C" fn(E, T, u32, *mut u32) -> bool,
    pub get_payload: unsafe extern "C" fn(E, T, u32, u32, *mut T) -> bool,
    pub resource_new: unsafe extern "C" fn(E, u32, *mut T) -> *mut c_void,
    pub get_resource: unsafe extern "C" fn(E, T, u32, *mut *mut c_void) -> bool,
    pub blocking: unsafe extern "C" fn(E, unsafe extern "C" fn(*mut c_void), *mut c_void),
}

/// The one export of a module, `agentica_native_init`.
pub type an_init = unsafe extern "C" fn(api: *const an_api) -> *const an_module;

// SAFETY: the pointers of the tables point at read-only data (names, signatures, shapes and the other tables) that
// lives as long as the module, as agentica_native.h asks, so the tables can be statics shared by every thread.
unsafe impl Sync for an_function {}
unsafe impl Sync for an_type {}
unsafe impl Sync for an_resource_type {}
unsafe impl Sync for an_module {}

// The sizes of the C layouts on a 64-bit target, so a field added or moved here fails the build.
#[cfg(target_pointer_width = "64")]
const _: () = {
    use core::mem::size_of;
    assert!(size_of::<an_term>() == 16);
    assert!(size_of::<an_api>() == 328);
    assert!(size_of::<an_module>() == 80);
    assert!(size_of::<an_function>() == 32);
    assert!(size_of::<an_type>() == 24);
    assert!(size_of::<an_resource_type>() == 24);
    assert!(size_of::<an_list_builder>() == 64);
};
