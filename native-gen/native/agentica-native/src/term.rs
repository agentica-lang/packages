//! `Env` and `Term`: one call of the VM and a value of it, both valid only during that call.
//!
//! The collector of the VM finds values only through the C stack and its own memory, never through Rust's heap. So in
//! a short call the `Env` keeps every term it makes in a root list that lives in the frame of `call`: a term made in
//! the call stays alive until the call returns, wherever Rust keeps it (a `Vec<Term>` included). A term that a getter
//! gives is a part of an argument or of a made term, so it lives as long as they do. A dirty call makes no collected
//! values (the VM stages them), so it keeps no root list. A cursor holds memory of the collector too, so a walk over a
//! List or a Map runs inside a closure, with its cursor in the frame of the walk.

use core::ffi::{c_char, c_int, c_void};
use core::fmt;
use core::iter::FusedIterator;
use core::marker::PhantomData;
use core::{mem, ptr};
use std::any::Any;
use std::borrow::Cow;
use std::panic::{AssertUnwindSafe, catch_unwind};

use crate::sys;

/// The mode of a function: `def` is `Short` (it runs on the calling scheduler), `compute def` `Dirty` (on the
/// compute pool, where the VM stages what it makes and a getter gives `None` for a staged term).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Short,
    Dirty,
}

/// What a row of the module's type table takes: the number of fields of a struct, or the payload count of each
/// variant of an enum, in declared order. The VM reads that many terms from what `make_struct` and `make_enum` pass,
/// so `Env` checks the length first. `Module` derives it from the row's shape.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Arity {
    Struct(usize),
    Enum(Cow<'static, [usize]>),
}

/// One call of the VM. The lifetime `'a` is the call, which only `call` chooses: a `Term<'a>` and what it lends
/// (`&'a str`, `&'a [u8]`) cannot leave it.
#[derive(Clone, Copy, Debug)]
pub struct Env<'a> {
    raw: *mut sys::an_env,
    // The root list of a short call (in the frame of `call`), null in a dirty one.
    roots: *mut sys::an_list_builder,
    types: &'a [Arity],
    // Invariant in 'a, so a term of one call never passes for a term of another.
    _call: PhantomData<fn(&'a ()) -> &'a ()>,
}

/// A value of the VM, valid until the call that got or made it returns.
#[derive(Clone, Copy, Debug)]
pub struct Term<'a> {
    raw: sys::an_term,
    env: Env<'a>,
}

/// The arguments of a call.
#[derive(Clone, Copy, Debug)]
pub struct Args<'a> {
    env: Env<'a>,
    argv: &'a [sys::an_term],
}

impl<'a> Args<'a> {
    pub fn len(&self) -> usize {
        self.argv.len()
    }

    pub fn is_empty(&self) -> bool {
        self.argv.is_empty()
    }

    /// The argument `index`, from 0.
    pub fn get(&self, index: usize) -> Option<Term<'a>> {
        self.argv.get(index).map(|&raw| self.env.read(raw))
    }
}

/// Runs `body` for one call of the VM and gives its result to the VM. `types` is what each row of the module's type
/// table takes.
///
/// `Err(Raise)` fails the call with its message (`RUNTIME-NATIVE-ERROR`), and so does a panic, caught here with the
/// message "panic: TEXT": nothing unwinds into the VM. The panic hook still prints its report, and what `body`
/// borrowed may be left half changed by the panic.
///
/// A failure of the VM itself is another thing: when the VM finds its own state broken inside an API function
/// (`RUNTIME-INTERNAL`, such as a Map whose key list does not match its table when a walk of it starts), it fails the
/// task with `agc_fail`, which leaves the call by `longjmp`. The jump skips every Rust frame between the VM and that
/// API function, `call` included. Rust defines such a jump only over frames with nothing to drop, so this one is
/// undefined behavior; in practice no destructor runs and no panic is caught, what those frames own leaks, and a lock
/// they hold stays held. Only a bug of the VM leads there, and the crate cannot stop it.
///
/// The env and its terms are valid only inside `body`:
///
/// ```compile_fail,E0521
/// # use agentica_native::*;
/// let mut kept = None;
/// unsafe {
///     call(std::ptr::null_mut(), 0, std::ptr::null(), Mode::Short, &[], |env, _| {
///         kept = Some(env.int(1));
///         Ok(env.void())
///     })
/// };
/// ```
///
/// ```compile_fail,E0521
/// # use agentica_native::*;
/// thread_local! { static KEPT: std::cell::Cell<Option<Term<'static>>> = std::cell::Cell::new(None); }
/// unsafe {
///     call(std::ptr::null_mut(), 0, std::ptr::null(), Mode::Short, &[], |env, _| {
///         KEPT.set(Some(env.int(1)));
///         Ok(env.void())
///     })
/// };
/// ```
///
/// A term of one call is not a term of another, and none crosses to another thread:
///
/// ```compile_fail
/// # use agentica_native::*;
/// unsafe {
///     call(std::ptr::null_mut(), 0, std::ptr::null(), Mode::Short, &[], |outer, _| {
///         let one = outer.int(1);
///         call(std::ptr::null_mut(), 0, std::ptr::null(), Mode::Short, &[], |inner, _| Ok(inner.list_of(&[one])));
///         Ok(outer.void())
///     })
/// };
/// ```
///
/// ```compile_fail,E0277
/// # use agentica_native::*;
/// unsafe {
///     call(std::ptr::null_mut(), 0, std::ptr::null(), Mode::Short, &[], |env, _| {
///         let one = env.int(1);
///         std::thread::spawn(move || one.get_int());
///         Ok(env.void())
///     })
/// };
/// ```
///
/// Each case without its escape compiles: a Rust value leaves the call, a term stays in it, and a thread gets a
/// Rust value (the case of two calls fails with no error code, so this twin is its check):
///
/// ```no_run
/// # use agentica_native::*;
/// thread_local! { static KEPT: std::cell::Cell<Option<i64>> = std::cell::Cell::new(None); }
/// let mut kept = None;
/// unsafe {
///     call(std::ptr::null_mut(), 0, std::ptr::null(), Mode::Short, &[], |outer, _| {
///         let one = outer.int(1);
///         kept = one.get_int();
///         KEPT.set(one.get_int());
///         let n = one.get_int();
///         std::thread::spawn(move || n);
///         call(std::ptr::null_mut(), 0, std::ptr::null(), Mode::Short, &[], |inner, _| Ok(inner.list_of(&[inner.int(1)])));
///         Ok(outer.list_of(&[one]))
///     })
/// };
/// ```
///
/// # Safety
///
/// `raw`, `argc` and `argv` are what the VM passed to a function of the module's table, whose mode is `mode`, and
/// `types` matches the module's type table.
pub unsafe fn call(
    raw: *mut sys::an_env,
    argc: c_int,
    argv: *const sys::an_term,
    mode: Mode,
    types: &[Arity],
    body: impl for<'a> FnOnce(Env<'a>, Args<'a>) -> Result<Term<'a>, Raise>,
) -> sys::an_term {
    // The root list of a short call: in this frame, which the collector scans, for as long as `body` runs. It is never
    // ended; its items die with the call.
    let mut roots = sys::an_list_builder { opaque: [0; 8] };
    let roots = match mode {
        Mode::Short => {
            // SAFETY: the env is the VM's, for this call; the builder lives in this frame until the call returns.
            unsafe { (api(raw).list_begin)(raw, &mut roots, 0) };
            &mut roots as *mut sys::an_list_builder
        }
        Mode::Dirty => ptr::null_mut(),
    };
    let env = Env { raw, roots, types, _call: PhantomData };
    let argv: &[sys::an_term] = if argv.is_null() || argc <= 0 {
        &[]
    } else {
        // SAFETY: the VM passes ARGC arguments, valid for the call.
        unsafe { core::slice::from_raw_parts(argv, argc as usize) }
    };
    let message = match catch_unwind(AssertUnwindSafe(|| body(env, Args { env, argv }))) {
        // The term is a root of this frame or a part of an argument, so it is alive until the VM takes it.
        Ok(Ok(term)) => return term.raw,
        Ok(Err(raise)) => raise.0,
        Err(payload) => panic_message(payload),
    };
    env.raise(&message).raw
}

/// The failure of a call, which `call` gives to the VM as the message of `RUNTIME-NATIVE-ERROR`: the one way a
/// function of a module fails. A `DecodeError` and a `String` become one with `?`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Raise(String);

impl Raise {
    pub fn new(message: impl Into<String>) -> Self {
        Raise(message.into())
    }

    pub fn message(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for Raise {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl From<String> for Raise {
    fn from(message: String) -> Self {
        Raise(message)
    }
}

impl From<&str> for Raise {
    fn from(message: &str) -> Self {
        Raise(message.to_string())
    }
}

/// The message of a caught panic, "panic: TEXT". The payload is dropped here, where a second panic of its own drop
/// is caught too: nothing unwinds into the VM.
fn panic_message(payload: Box<dyn Any + Send>) -> String {
    let text =
        payload.downcast_ref::<&str>().map(|s| s.to_string()).or_else(|| payload.downcast_ref::<String>().cloned());
    if let Err(again) = catch_unwind(AssertUnwindSafe(|| drop(payload))) {
        mem::forget(again);
    }
    match text {
        Some(text) => format!("panic: {text}"),
        None => "panic".to_string(),
    }
}

/// The table of the call.
///
/// # Safety
///
/// `raw` is the env that the VM passed to the running call: it starts with a pointer to the table of the call
/// (an_api_of in agentica_native.h), which outlives `'a`.
unsafe fn api<'a>(raw: *mut sys::an_env) -> &'a sys::an_api {
    unsafe { &**(raw as *const *const sys::an_api) }
}

impl<'a> Env<'a> {
    fn api(self) -> &'a sys::an_api {
        // SAFETY: only `call` makes an Env, from the env of the running call, and `'a` ends with that call.
        unsafe { api(self.raw) }
    }

    /// A term that a getter gave: a part of an argument or of a made term.
    fn read(self, raw: sys::an_term) -> Term<'a> {
        Term { raw, env: self }
    }

    /// A term that needs no memory of the collector: the VM makes an Int, Float, Bool or Void as an immediate value
    /// (api_int, api_float, api_bool and api_void of vm/native_module.c build them with agc_int and the others of
    /// vm/value.h), and a failure gives Void (env_fail), so the root list does not keep them.
    fn immediate(self, raw: sys::an_term) -> Term<'a> {
        Term { raw, env: self }
    }

    /// A term that a constructor made, kept in the root list of a short call.
    fn made(self, raw: sys::an_term) -> Term<'a> {
        if !self.roots.is_null() {
            // SAFETY: the root list is in the frame of `call`, which outlives every Env of the call.
            unsafe { (self.api().list_push)(self.raw, self.roots, raw) };
        }
        Term { raw, env: self }
    }

    /// Whether `self` and `other` are the env of one live call. The VM's env is a local of its call, so one address
    /// serves consecutive calls, and a nested `call` on the same env is another frame: the root list (the address of
    /// the builder in the frame of `call`) tells two live short calls apart. Two dirty calls on one env both have no
    /// root list, and their staged values last until the VM's call ends, so one is as good as the other.
    pub(crate) fn same_call(self, other: Env<'_>) -> bool {
        self.raw == other.raw && self.roots == other.roots
    }

    pub fn mode(self) -> Mode {
        if self.roots.is_null() { Mode::Dirty } else { Mode::Short }
    }

    // SAFETY (each constructor below): the env is the VM's for this call, and every pointer passed is valid for the
    // length passed with it, or is a local of the constructor.

    pub fn int(self, n: i64) -> Term<'a> {
        self.immediate(unsafe { (self.api().make_int)(self.raw, n) })
    }

    pub fn float(self, x: f64) -> Term<'a> {
        self.immediate(unsafe { (self.api().make_float)(self.raw, x) })
    }

    pub fn bool(self, b: bool) -> Term<'a> {
        self.immediate(unsafe { (self.api().make_bool)(self.raw, b) })
    }

    pub fn void(self) -> Term<'a> {
        self.immediate(unsafe { (self.api().make_void)(self.raw) })
    }

    pub fn string(self, text: &str) -> Term<'a> {
        self.made(unsafe { (self.api().make_string)(self.raw, text.as_ptr() as *const c_char, text.len()) })
    }

    pub fn bytes(self, data: &[u8]) -> Term<'a> {
        self.made(unsafe { (self.api().make_bytes)(self.raw, data.as_ptr() as *const c_void, data.len()) })
    }

    /// A Bytes of `len` bytes that `fill` writes in place.
    pub fn bytes_with(self, len: usize, fill: impl FnOnce(&mut [u8])) -> Term<'a> {
        let mut data = ptr::null_mut();
        let term = self.made(unsafe { (self.api().bytes_fill)(self.raw, len, &mut data) });
        if !data.is_null() && len > 0 {
            // SAFETY: the VM gave LEN zeroed bytes at DATA, owned by the new term, which nothing else reads yet.
            fill(unsafe { core::slice::from_raw_parts_mut(data, len) });
        }
        term
    }

    /// A List of `items`, copied.
    pub fn list_of(self, items: &[Term<'a>]) -> Term<'a> {
        with_raw(items, |raw| self.made(unsafe { (self.api().make_list)(self.raw, raw.as_ptr(), raw.len()) }))
    }

    /// A List of the terms that `items` gives, pushed one at a time into a builder in this frame.
    pub fn list<I: IntoIterator<Item = Term<'a>>>(self, items: I) -> Term<'a> {
        let items = items.into_iter();
        let mut builder = sys::an_list_builder { opaque: [0; 8] };
        // SAFETY: the builder stays in this frame from begin to end.
        unsafe { (self.api().list_begin)(self.raw, &mut builder, items.size_hint().0) };
        for item in items {
            // SAFETY: as above.
            unsafe { (self.api().list_push)(self.raw, &mut builder, item.raw) };
        }
        self.made(unsafe { (self.api().list_end)(self.raw, &mut builder) })
    }

    /// A Map of the pairs that `pairs` gives, in their order; a later pair of one key replaces the earlier one. The VM
    /// makes it in one pass from the keys and values, gathered on the stack for up to 16 pairs.
    pub fn map<I: IntoIterator<Item = (Term<'a>, Term<'a>)>>(self, pairs: I) -> Term<'a> {
        const SHORT: usize = 16;
        let blank = sys::an_term { opaque: [0; 2] };
        let (mut keys, mut values) = ([blank; SHORT], [blank; SHORT]);
        let (mut more_keys, mut more_values) = (Vec::new(), Vec::new());
        let mut n = 0;
        for (key, value) in pairs {
            if n < SHORT {
                (keys[n], values[n]) = (key.raw, value.raw);
            } else {
                // Past the stack buffers, a copy on the heap: each term is a root of the call or a part of one.
                if n == SHORT {
                    more_keys.extend_from_slice(&keys);
                    more_values.extend_from_slice(&values);
                }
                more_keys.push(key.raw);
                more_values.push(value.raw);
            }
            n += 1;
        }
        let (k, v) = if n <= SHORT { (&keys[..n], &values[..n]) } else { (&more_keys[..], &more_values[..]) };
        // SAFETY: both slices hold N terms of this call.
        self.made(unsafe { (self.api().map_from)(self.raw, k.as_ptr(), v.as_ptr(), n) })
    }

    pub fn none(self) -> Term<'a> {
        self.made(unsafe { (self.api().make_none)(self.raw) })
    }

    pub fn some(self, value: Term<'a>) -> Term<'a> {
        self.made(unsafe { (self.api().make_some)(self.raw, value.raw) })
    }

    pub fn ok(self, value: Term<'a>) -> Term<'a> {
        self.made(unsafe { (self.api().make_ok)(self.raw, value.raw) })
    }

    pub fn error(self, message: &str) -> Term<'a> {
        self.made(unsafe { (self.api().make_error)(self.raw, message.as_ptr() as *const c_char, message.len()) })
    }

    /// A struct of row `type_` of the type table, with one term per field in declared order. Another number of
    /// fields, or a row that is not a struct, fails the call.
    pub fn make_struct(self, type_: u32, fields: &[Term<'a>]) -> Term<'a> {
        match self.types.get(type_ as usize) {
            Some(Arity::Struct(n)) if *n == fields.len() => {}
            _ => {
                return self.raise(&format!("make_struct: row {type_} does not take {} fields", fields.len()));
            }
        }
        // SAFETY: the row takes exactly as many fields as the slice holds.
        with_raw(fields, |raw| self.made(unsafe { (self.api().make_struct)(self.raw, type_, raw.as_ptr()) }))
    }

    /// The variant `variant` of the enum of row `type_`, with its payload (empty for a variant without one). Another
    /// payload count, or a row or variant that is not there, fails the call.
    pub fn make_enum(self, type_: u32, variant: u32, payload: &[Term<'a>]) -> Term<'a> {
        match self.types.get(type_ as usize) {
            Some(Arity::Enum(variants)) if variants.get(variant as usize) == Some(&payload.len()) => {}
            _ => {
                let message = format!("make_enum: row {type_} has no variant {variant} of {} payloads", payload.len());
                return self.raise(&message);
            }
        }
        with_raw(payload, |raw| {
            let at = if raw.is_empty() { ptr::null() } else { raw.as_ptr() };
            // SAFETY: the variant takes exactly as many payloads as the slice holds.
            self.made(unsafe { (self.api().make_enum)(self.raw, type_, variant, at) })
        })
    }

    /// A new resource of row `type_` and its zeroed state, or `None` when the VM refused it (the call has failed). The
    /// VM owns the state: it frees it (after the free function of the row) at `Native.close`, at the end of the task
    /// that owns the resource, or at the end of the run, so the pointer must not be kept past the call.
    pub fn resource_new(self, type_: u32) -> (Term<'a>, Option<*mut c_void>) {
        let mut out = sys::an_term { opaque: [0; 2] };
        // The VM sets OUT in every case (to Void when it refuses).
        let state = unsafe { (self.api().resource_new)(self.raw, type_, &mut out) };
        (self.made(out), if state.is_null() { None } else { Some(state) })
    }

    /// Fails the call with `message` once it returns. The first failure of a call wins. A module fails a call with
    /// `Err(Raise)`; this is for `call` and the constructors of the crate.
    pub(crate) fn raise(self, message: &str) -> Term<'a> {
        // The VM copies a NUL-terminated message: cut it at a NUL inside, which C would read as its end anyway.
        let text = message.split('\0').next().unwrap_or("");
        let mut owned = Vec::with_capacity(text.len() + 1);
        owned.extend_from_slice(text.as_bytes());
        owned.push(0);
        self.immediate(unsafe { (self.api().raise)(self.raw, owned.as_ptr() as *const c_char) })
    }
}

/// `f` of the raw terms of `terms`: on the stack for up to 16 of them. A longer copy on the heap is safe as well, since
/// each term is a root of the call or a part of one.
fn with_raw<R>(terms: &[Term<'_>], f: impl FnOnce(&[sys::an_term]) -> R) -> R {
    const SHORT: usize = 16;
    if terms.len() <= SHORT {
        let mut buffer = [sys::an_term { opaque: [0; 2] }; SHORT];
        for (slot, term) in buffer.iter_mut().zip(terms) {
            *slot = term.raw;
        }
        f(&buffer[..terms.len()])
    } else {
        f(&terms.iter().map(|t| t.raw).collect::<Vec<_>>())
    }
}

/// The getters. Each gives `None` for a term of another type, and in a dirty call for a term the VM staged. Which made
/// terms are staged is the VM's choice, so a dirty call must not read back what it made.
impl<'a> Term<'a> {
    pub fn as_raw(self) -> sys::an_term {
        self.raw
    }

    pub fn env(self) -> Env<'a> {
        self.env
    }

    /// The term with `env` for its env.
    ///
    /// # Safety
    ///
    /// `env` is the env of the call that the term belongs to.
    pub(crate) unsafe fn rebind<'b>(self, env: Env<'b>) -> Term<'b> {
        Term { raw: self.raw, env }
    }

    fn api(self) -> &'a sys::an_api {
        self.env.api()
    }

    fn e(self) -> *mut sys::an_env {
        self.env.raw
    }

    // SAFETY (each getter below): the env is the VM's for this call, and every out pointer is a local of the getter.

    pub fn get_int(self) -> Option<i64> {
        let mut n = 0;
        unsafe { (self.api().get_int)(self.e(), self.raw, &mut n) }.then_some(n)
    }

    pub fn get_float(self) -> Option<f64> {
        let mut x = 0.0;
        unsafe { (self.api().get_float)(self.e(), self.raw, &mut x) }.then_some(x)
    }

    pub fn get_bool(self) -> Option<bool> {
        let mut b = false;
        unsafe { (self.api().get_bool)(self.e(), self.raw, &mut b) }.then_some(b)
    }

    /// The text of a String, borrowed for the call.
    pub fn get_str(self) -> Option<&'a str> {
        let mut data = ptr::null();
        let mut len = 0;
        if !unsafe { (self.api().get_string)(self.e(), self.raw, &mut data, &mut len) } {
            return None;
        }
        // SAFETY: the VM gives LEN bytes at DATA for the call, and String data is UTF-8 (agentica_native.h).
        let bytes = unsafe { slice(data as *const u8, len) };
        debug_assert!(core::str::from_utf8(bytes).is_ok());
        Some(unsafe { core::str::from_utf8_unchecked(bytes) })
    }

    /// The data of a Bytes, borrowed for the call.
    pub fn get_bytes(self) -> Option<&'a [u8]> {
        let mut data = ptr::null();
        let mut len = 0;
        // SAFETY: the VM gives LEN bytes at DATA for the call.
        unsafe { (self.api().get_bytes)(self.e(), self.raw, &mut data, &mut len) }.then(|| unsafe { slice(data, len) })
    }

    /// `walk` of the items of a List, in order; `None` for another term.
    pub fn list_items<R>(self, walk: impl FnOnce(&mut ListItems<'_, 'a>) -> R) -> Option<R> {
        let mut cursor = sys::an_list_cursor { opaque: [0; 8] };
        let mut len = 0;
        if !unsafe { (self.api().list_cursor)(self.e(), self.raw, &mut cursor, &mut len) } {
            return None;
        }
        Some(walk(&mut ListItems { cursor: &mut cursor, left: len, env: self.env }))
    }

    /// `walk` of the pairs of a Map, in insertion order; `None` for another term.
    pub fn map_pairs<R>(self, walk: impl FnOnce(&mut MapPairs<'_, 'a>) -> R) -> Option<R> {
        let mut cursor = sys::an_map_cursor { opaque: [0; 8] };
        let mut len = 0;
        if !unsafe { (self.api().map_cursor)(self.e(), self.raw, &mut cursor, &mut len) } {
            return None;
        }
        Some(walk(&mut MapPairs { cursor: &mut cursor, left: len, env: self.env }))
    }

    /// The value of `key` in a Map; `None` for a missing key or another term.
    pub fn map_get(self, key: Term<'a>) -> Option<Term<'a>> {
        let mut value = self.raw;
        unsafe { (self.api().map_get)(self.e(), self.raw, key.raw, &mut value) }.then(|| self.env.read(value))
    }

    /// An Optional as `Some(Some(value))` or `Some(None)`.
    pub fn get_optional(self) -> Option<Option<Term<'a>>> {
        let mut some = false;
        let mut value = self.raw;
        unsafe { (self.api().get_optional)(self.e(), self.raw, &mut some, &mut value) }
            .then(|| some.then(|| self.env.read(value)))
    }

    /// A Result as `Ok(value)` or `Err(message)`, the message a String term.
    pub fn get_result(self) -> Option<Result<Term<'a>, Term<'a>>> {
        let mut ok = false;
        let mut value = self.raw;
        unsafe { (self.api().get_result)(self.e(), self.raw, &mut ok, &mut value) }.then(|| {
            let value = self.env.read(value);
            if ok { Ok(value) } else { Err(value) }
        })
    }

    /// The field `field` of a struct of row `type_`.
    pub fn get_field(self, type_: u32, field: u32) -> Option<Term<'a>> {
        let mut out = self.raw;
        unsafe { (self.api().get_field)(self.e(), self.raw, type_, field, &mut out) }.then(|| self.env.read(out))
    }

    /// The variant of an enum of row `type_`.
    pub fn get_variant(self, type_: u32) -> Option<u32> {
        let mut variant = 0;
        unsafe { (self.api().get_variant)(self.e(), self.raw, type_, &mut variant) }.then_some(variant)
    }

    /// The payload `k` of the variant of an enum of row `type_`.
    pub fn get_payload(self, type_: u32, k: u32) -> Option<Term<'a>> {
        let mut out = self.raw;
        unsafe { (self.api().get_payload)(self.e(), self.raw, type_, k, &mut out) }.then(|| self.env.read(out))
    }

    /// The state of a resource of row `type_` that is an argument of the call (not one that the call made). The VM
    /// holds the resource open for the call and may free the state after it, so the pointer is valid for the call only.
    pub fn get_resource(self, type_: u32) -> Option<*mut c_void> {
        let mut state = ptr::null_mut();
        unsafe { (self.api().get_resource)(self.e(), self.raw, type_, &mut state) }.then_some(state)
    }
}

/// A slice the VM gave for the call; an empty one may come with a null pointer, which a Rust slice cannot have.
///
/// # Safety
///
/// `data` holds `len` bytes for `'a`.
unsafe fn slice<'a>(data: *const u8, len: usize) -> &'a [u8] {
    if len == 0 { &[] } else { unsafe { core::slice::from_raw_parts(data, len) } }
}

/// The items of a List, through a cursor in the frame of `Term::list_items`.
pub struct ListItems<'c, 'a> {
    cursor: &'c mut sys::an_list_cursor,
    left: usize,
    env: Env<'a>,
}

impl<'a> Iterator for ListItems<'_, 'a> {
    type Item = Term<'a>;

    fn next(&mut self) -> Option<Term<'a>> {
        if self.left == 0 {
            return None;
        }
        let mut item = sys::an_term { opaque: [0; 2] };
        // SAFETY: the VM began the cursor in this call, and it lives in the frame of the walk.
        if !unsafe { (self.env.api().list_next)(self.env.raw, self.cursor, &mut item) } {
            self.left = 0;
            return None;
        }
        self.left -= 1;
        Some(self.env.read(item))
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        (self.left, Some(self.left))
    }
}

impl ExactSizeIterator for ListItems<'_, '_> {}
impl FusedIterator for ListItems<'_, '_> {}

/// The pairs of a Map, through a cursor in the frame of `Term::map_pairs`.
pub struct MapPairs<'c, 'a> {
    cursor: &'c mut sys::an_map_cursor,
    left: usize,
    env: Env<'a>,
}

impl<'a> Iterator for MapPairs<'_, 'a> {
    type Item = (Term<'a>, Term<'a>);

    fn next(&mut self) -> Option<(Term<'a>, Term<'a>)> {
        if self.left == 0 {
            return None;
        }
        let mut key = sys::an_term { opaque: [0; 2] };
        let mut value = key;
        // SAFETY: the VM began the cursor in this call, and it lives in the frame of the walk.
        if !unsafe { (self.env.api().map_next)(self.env.raw, self.cursor, &mut key, &mut value) } {
            self.left = 0;
            return None;
        }
        self.left -= 1;
        Some((self.env.read(key), self.env.read(value)))
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        (self.left, Some(self.left))
    }
}

impl ExactSizeIterator for MapPairs<'_, '_> {}
impl FusedIterator for MapPairs<'_, '_> {}
