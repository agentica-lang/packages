//! `Env` and `Term`: one call of the VM and a value of it, both valid only during that call.
//!
//! The collector of the VM finds values only through the C stack and its own memory, never through Rust's heap. So in
//! a short call the `Env` keeps every term it makes in a root list that lives in the frame of `call`: a term made in
//! the call stays alive until the call returns, wherever Rust keeps it (a `Vec<Term>` included). A term that a getter
//! gives is a part of an argument or of a made term, so it lives as long as they do. A dirty call makes no collected
//! values (the VM stages them), so it keeps no root list. A cursor holds memory of the collector too, so a walk over a
//! List or a Map runs inside a closure, with its cursor in the frame of the walk.

use core::ffi::{c_char, c_int, c_void};
use core::iter::FusedIterator;
use core::marker::PhantomData;
use core::ptr;

use crate::sys;

/// The mode of a function: `def` is `Short` (it runs on the calling scheduler), `compute def` `Dirty` (on the
/// compute pool, where the VM stages what it makes and a getter refuses a staged term).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Short,
    Dirty,
}

/// What a row of the module's type table takes: the number of fields of a struct, or the payload count of each
/// variant of an enum, in declared order. The VM reads that many terms from what `make_struct` and `make_enum` pass,
/// so `Env` checks the length first.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Arity {
    Struct(usize),
    Enum(Vec<usize>),
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
/// table takes. The env and its terms are valid only inside `body`:
///
/// ```compile_fail
/// # use agentica_native::*;
/// let mut kept = None;
/// unsafe {
///     call(std::ptr::null_mut(), 0, std::ptr::null(), Mode::Short, &[], |env, _| {
///         kept = Some(env.int(1));
///         env.void()
///     })
/// };
/// ```
///
/// ```compile_fail
/// # use agentica_native::*;
/// thread_local! { static KEPT: std::cell::Cell<Option<Term<'static>>> = std::cell::Cell::new(None); }
/// unsafe {
///     call(std::ptr::null_mut(), 0, std::ptr::null(), Mode::Short, &[], |env, _| {
///         KEPT.set(Some(env.int(1)));
///         env.void()
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
///         call(std::ptr::null_mut(), 0, std::ptr::null(), Mode::Short, &[], |inner, _| inner.some(one));
///         outer.void()
///     })
/// };
/// ```
///
/// ```compile_fail
/// # use agentica_native::*;
/// unsafe {
///     call(std::ptr::null_mut(), 0, std::ptr::null(), Mode::Short, &[], |env, _| {
///         let one = env.int(1);
///         std::thread::spawn(move || one.get_int());
///         env.void()
///     })
/// };
/// ```
///
/// The same body without the escape compiles:
///
/// ```no_run
/// # use agentica_native::*;
/// unsafe {
///     call(std::ptr::null_mut(), 0, std::ptr::null(), Mode::Short, &[], |outer, _| {
///         let one = outer.int(1);
///         call(std::ptr::null_mut(), 0, std::ptr::null(), Mode::Short, &[], |inner, _| inner.some(inner.int(1)));
///         outer.some(one)
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
    body: impl for<'a> FnOnce(Env<'a>, Args<'a>) -> Term<'a>,
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
    body(env, Args { env, argv }).raw
}

/// The table of the call.
fn api<'a>(raw: *mut sys::an_env) -> &'a sys::an_api {
    // SAFETY: the VM's env starts with a pointer to the table of the call (an_api_of in agentica_native.h), which
    // outlives the call.
    unsafe { &**(raw as *const *const sys::an_api) }
}

impl<'a> Env<'a> {
    fn api(self) -> &'a sys::an_api {
        api(self.raw)
    }

    /// A term that a getter gave: a part of an argument or of a made term.
    fn read(self, raw: sys::an_term) -> Term<'a> {
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

    pub fn mode(self) -> Mode {
        if self.roots.is_null() { Mode::Dirty } else { Mode::Short }
    }

    // SAFETY (each constructor below): the env is the VM's for this call, and every pointer passed is valid for the
    // length passed with it, or is a local of the constructor.

    pub fn int(self, n: i64) -> Term<'a> {
        self.made(unsafe { (self.api().make_int)(self.raw, n) })
    }

    pub fn float(self, x: f64) -> Term<'a> {
        self.made(unsafe { (self.api().make_float)(self.raw, x) })
    }

    pub fn bool(self, b: bool) -> Term<'a> {
        self.made(unsafe { (self.api().make_bool)(self.raw, b) })
    }

    pub fn void(self) -> Term<'a> {
        self.made(unsafe { (self.api().make_void)(self.raw) })
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

    /// A Map of the pairs that `pairs` gives, in their order; a later pair of one key replaces the earlier one.
    pub fn map<I: IntoIterator<Item = (Term<'a>, Term<'a>)>>(self, pairs: I) -> Term<'a> {
        let mut map = self.made(unsafe { (self.api().map_from)(self.raw, ptr::null(), ptr::null(), 0) });
        for (key, value) in pairs {
            // SAFETY: the env is the VM's for this call.
            map = self.made(unsafe { (self.api().map_put)(self.raw, map.raw, key.raw, value.raw) });
        }
        map
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

    /// A new resource of row `type_` and its zeroed state, or `None` when the VM refused it (the call has failed).
    pub fn resource_new(self, type_: u32) -> (Term<'a>, Option<*mut c_void>) {
        let mut out = sys::an_term { opaque: [0; 2] };
        // The VM sets OUT in every case (to Void when it refuses).
        let state = unsafe { (self.api().resource_new)(self.raw, type_, &mut out) };
        (self.made(out), if state.is_null() { None } else { Some(state) })
    }

    /// Fails the call with `message` once it returns. The first failure of a call wins.
    pub fn raise(self, message: &str) -> Term<'a> {
        // The VM copies a NUL-terminated message: cut it at a NUL inside, which C would read as its end anyway.
        let text = message.split('\0').next().unwrap_or("");
        let mut owned = Vec::with_capacity(text.len() + 1);
        owned.extend_from_slice(text.as_bytes());
        owned.push(0);
        self.made(unsafe { (self.api().raise)(self.raw, owned.as_ptr() as *const c_char) })
    }

    /// Fails the call with "argument INDEX + 1 is not valid".
    pub fn badarg(self, index: usize) -> Term<'a> {
        self.made(unsafe { (self.api().badarg)(self.raw, c_int::try_from(index).unwrap_or(c_int::MAX)) })
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

/// The getters. Each gives `None` for a term of another type; in a dirty call, also for one that the call made and
/// the VM staged (anything but a scalar).
impl<'a> Term<'a> {
    pub fn as_raw(self) -> sys::an_term {
        self.raw
    }

    pub fn env(self) -> Env<'a> {
        self.env
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

    /// The state of a resource of row `type_` that is an argument of the call (not one that the call made).
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
