//! `ResourceArc<T>`: a Rust value that the program holds as a resource of the module, which `Drop` frees.

use core::ffi::c_void;
use core::ops::Deref;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;

use crate::codec::{DecodeError, Decoder, Encoder};
use crate::module::resource_row;
use crate::term::{Env, Term};

/// A shared `T` that crosses to the program as a resource of the module (`Module::resource::<T>`). The state of the
/// resource holds one count of the `Arc`, which the VM's free of it drops: at `Native.close`, at the end of the task
/// that owns it, or at the end of the run. A decoded argument holds a count of its own, so Rust may keep a clone after
/// the call; `T` is dropped when both the program and Rust are done with it. Encoding a `ResourceArc` makes a new
/// resource of the program that shares the same `T` (the program's `==` tells the two apart).
///
/// The calls of every scheduler share `T`, and the VM drops it on a thread of its own, so `T` is `Send + Sync`.
///
/// Two cases never drop `T`: a resource that a dirty call made, when the run ends before the call's result is taken
/// (`agc_native_dirty_free` frees its state as memory alone, without the row's free function); and a resource that a
/// dirty call still running at the end of the run holds as an argument (the end of the run skips the free of a
/// resource a compute call holds, and does not wait for the call). So a value that must flush or finish something
/// should get an explicit close of its own, not rely on `Drop` alone.
pub struct ResourceArc<T: Send + Sync + 'static>(Arc<T>);

impl<T: Send + Sync + 'static> ResourceArc<T> {
    pub fn new(value: T) -> Self {
        ResourceArc(Arc::new(value))
    }

    /// Whether `a` and `b` share one `T`.
    pub fn ptr_eq(a: &Self, b: &Self) -> bool {
        Arc::ptr_eq(&a.0, &b.0)
    }
}

impl<T: Send + Sync + 'static> Clone for ResourceArc<T> {
    fn clone(&self) -> Self {
        ResourceArc(Arc::clone(&self.0))
    }
}

impl<T: Send + Sync + 'static> Deref for ResourceArc<T> {
    type Target = T;

    fn deref(&self) -> &T {
        &self.0
    }
}

impl<T: Send + Sync + 'static> std::fmt::Debug for ResourceArc<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "ResourceArc<{}>", std::any::type_name::<T>())
    }
}

impl<'a, T: Send + Sync + 'static> Decoder<'a> for ResourceArc<T> {
    fn type_name() -> String {
        resource_row::<T>().map_or_else(|| "a resource".to_string(), |(_, name)| name.to_string())
    }

    fn decode(term: Term<'a>) -> Result<Self, DecodeError> {
        let state = resource_row::<T>()
            .and_then(|(row, _)| term.get_resource(row))
            .ok_or_else(DecodeError::expected::<Self>)?;
        // SAFETY: the state of a row of T holds what encode wrote, a pointer of Arc::into_raw (or null if the call
        // that made it failed first), and the VM holds an argument open for the call.
        let raw = unsafe { *(state as *const *const T) };
        if raw.is_null() {
            return Err(DecodeError::expected::<Self>());
        }
        // SAFETY: the state keeps its count, so the Arc is alive; this adds the count of the new handle.
        unsafe {
            Arc::increment_strong_count(raw);
            Ok(ResourceArc(Arc::from_raw(raw)))
        }
    }
}

impl<T: Send + Sync + 'static> Encoder for ResourceArc<T> {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        let Some((row, _)) = resource_row::<T>() else {
            return env.raise(&format!("{} is not a resource of the module", std::any::type_name::<T>()));
        };
        match env.resource_new(row) {
            (term, Some(state)) => {
                // SAFETY: the state is the zeroed memory of the row, the size of a pointer (Module::resource), and
                // only this call has it until it returns.
                unsafe { *(state as *mut *const T) = Arc::into_raw(Arc::clone(&self.0)) };
                term
            }
            // The VM refused it and failed the call.
            (term, None) => term,
        }
    }
}

/// The free function of a resource row of `T`: drops the count that the state holds (none in a state still zeroed).
/// A panic of `Drop` stops here, as it must not unwind into the VM.
pub(crate) unsafe extern "C" fn free<T: Send + Sync + 'static>(state: *mut c_void) {
    // SAFETY: the VM gives the state of a row of T once, and frees its memory after this returns.
    let raw = unsafe { *(state as *const *const T) };
    if raw.is_null() {
        return;
    }
    // SAFETY: the state's count, given back once.
    let arc = unsafe { Arc::from_raw(raw) };
    if let Err(payload) = catch_unwind(AssertUnwindSafe(|| drop(arc)))
        && let Err(again) = catch_unwind(AssertUnwindSafe(|| drop(payload)))
    {
        core::mem::forget(again);
    }
}
