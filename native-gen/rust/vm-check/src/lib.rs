//! The functions of check.agc on `call`, `Env` and `Term`, with tables written by hand.

use core::ffi::c_int;
use core::ptr;

use agentica_native::{Mode, Term, call, sys};

/// `n` Strings, kept in a Vec of terms until the List is built: the root list of the call keeps them alive while
/// each new String may start a collection.
unsafe extern "C" fn strings(env: *mut sys::an_env, argc: c_int, argv: *const sys::an_term) -> sys::an_term {
    // SAFETY (each function): the VM passes its own env and arguments, and the mode is the one of the table.
    unsafe {
        call(env, argc, argv, Mode::Short, |env, args| {
            let n = args.get(0).and_then(Term::get_int).unwrap_or(0);
            let kept: Vec<Term> =
                (0..n).map(|k| env.string(&format!("a string long enough to live on the heap {k}"))).collect();
            env.list(kept)
        })
    }
}

macro_rules! function {
    ($name:literal, $signature:literal, $fn_:ident, $flags:expr) => {
        sys::an_function { name: $name.as_ptr(), signature: $signature.as_ptr(), fn_: $fn_, flags: $flags }
    };
}

static FUNCTIONS: [sys::an_function; 1] = [function!(c"strings", c"(Int) -> List[String]", strings, sys::AN_SHORT)];

static MODULE: sys::an_module = sys::an_module {
    major: sys::AN_API_MAJOR,
    minor: sys::AN_API_MINOR,
    size: size_of::<sys::an_module>() as u32,
    name: c"vm_check".as_ptr(),
    load: None,
    functions: FUNCTIONS.as_ptr(),
    function_count: FUNCTIONS.len() as u32,
    types: ptr::null(),
    type_count: 0,
    resources: ptr::null(),
    resource_count: 0,
};

/// The init of the module.
///
/// # Safety
///
/// Called by the VM only.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn agentica_native_init(_api: *const sys::an_api) -> *const sys::an_module {
    &MODULE
}
