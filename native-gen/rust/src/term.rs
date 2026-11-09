//! `Env` and `Term`: one call of the VM and a value of it, both valid only during that call.

use core::ffi::{c_char, c_void};
use core::marker::PhantomData;
use core::mem::MaybeUninit;
use core::ptr;

use crate::sys;

/// One call of the VM. The lifetime `'a` is the call: a `Term<'a>` and what a decoder borrows from it (`&'a str`,
/// `&'a [u8]`) cannot outlive it. The generated wrappers make one per call; module code never needs it.
#[derive(Clone, Copy, Debug)]
pub struct Env<'a> {
    raw: *mut sys::an_env,
    // Invariant in 'a, so a term of one call never passes for a term of another.
    _call: PhantomData<fn(&'a ()) -> &'a ()>,
}

/// A value of the VM, valid until the call that got or made it returns. Its data lives in the VM's collected memory,
/// which the collector finds only on the stack: keep terms in locals, never in a `Vec` or a `Box`.
#[derive(Clone, Copy, Debug)]
pub struct Term<'a> {
    raw: sys::an_term,
    env: Env<'a>,
}

impl<'a> Env<'a> {
    /// # Safety
    ///
    /// `raw` is the env of a call that lasts at least as long as `'a`.
    pub unsafe fn from_raw(raw: *mut sys::an_env) -> Self {
        Env {
            raw,
            _call: PhantomData,
        }
    }

    pub fn as_raw(self) -> *mut sys::an_env {
        self.raw
    }

    fn api(self) -> &'a sys::an_api {
        // SAFETY: the VM's env starts with a pointer to the table of the call (an_api_of in agentica_native.h).
        unsafe { &**(self.raw as *const *const sys::an_api) }
    }

    fn term(self, raw: sys::an_term) -> Term<'a> {
        Term { raw, env: self }
    }

    pub fn int(self, n: i64) -> Term<'a> {
        self.term(unsafe { (self.api().make_int)(self.raw, n) })
    }

    pub fn float(self, x: f64) -> Term<'a> {
        self.term(unsafe { (self.api().make_float)(self.raw, x) })
    }

    pub fn bool(self, b: bool) -> Term<'a> {
        self.term(unsafe { (self.api().make_bool)(self.raw, b) })
    }

    pub fn void(self) -> Term<'a> {
        self.term(unsafe { (self.api().make_void)(self.raw) })
    }

    pub fn string(self, text: &str) -> Term<'a> {
        self.term(unsafe { (self.api().make_string)(self.raw, text.as_ptr() as *const c_char, text.len()) })
    }

    pub fn bytes(self, data: &[u8]) -> Term<'a> {
        self.term(unsafe { (self.api().make_bytes)(self.raw, data.as_ptr() as *const c_void, data.len()) })
    }

    /// A List of the terms that `items` gives, pushed one at a time into a builder on the stack.
    pub fn list<I: IntoIterator<Item = Term<'a>>>(self, items: I) -> Term<'a> {
        let items = items.into_iter();
        let mut builder = MaybeUninit::<sys::an_list_builder>::uninit();
        unsafe {
            (self.api().list_begin)(self.raw, builder.as_mut_ptr(), items.size_hint().0);
            for item in items {
                (self.api().list_push)(self.raw, builder.as_mut_ptr(), item.raw);
            }
            self.term((self.api().list_end)(self.raw, builder.as_mut_ptr()))
        }
    }

    /// A Map of the pairs that `pairs` gives, in their order. Each pair is put into the map made so far, so no term
    /// waits in memory that the collector does not scan.
    pub fn map<I: IntoIterator<Item = (Term<'a>, Term<'a>)>>(self, pairs: I) -> Term<'a> {
        let mut map = self.term(unsafe { (self.api().map_from)(self.raw, ptr::null(), ptr::null(), 0) });
        for (key, value) in pairs {
            map = self.term(unsafe { (self.api().map_put)(self.raw, map.raw, key.raw, value.raw) });
        }
        map
    }

    pub fn none(self) -> Term<'a> {
        self.term(unsafe { (self.api().make_none)(self.raw) })
    }

    pub fn some(self, value: Term<'a>) -> Term<'a> {
        self.term(unsafe { (self.api().make_some)(self.raw, value.raw) })
    }

    pub fn ok(self, value: Term<'a>) -> Term<'a> {
        self.term(unsafe { (self.api().make_ok)(self.raw, value.raw) })
    }

    pub fn error(self, message: &str) -> Term<'a> {
        self.term(unsafe { (self.api().make_error)(self.raw, message.as_ptr() as *const c_char, message.len()) })
    }

    /// A struct of row `type_` of the type table, with one term per field in declared order.
    pub fn make_struct(self, type_: u32, fields: &[Term<'a>]) -> Term<'a> {
        let raw = raw_terms(fields);
        self.term(unsafe { (self.api().make_struct)(self.raw, type_, raw.as_ptr()) })
    }

    /// The variant `variant` of the enum of row `type_`, with its payload (empty for a variant without one).
    pub fn make_enum(self, type_: u32, variant: u32, payload: &[Term<'a>]) -> Term<'a> {
        let raw = raw_terms(payload);
        let at = if raw.is_empty() { ptr::null() } else { raw.as_ptr() };
        self.term(unsafe { (self.api().make_enum)(self.raw, type_, variant, at) })
    }

    /// A new resource of row `type_` and its zeroed state, or `None` when the VM refused it (the call has failed).
    pub fn resource_new(self, type_: u32) -> (Term<'a>, Option<*mut c_void>) {
        let mut out = MaybeUninit::<sys::an_term>::uninit();
        let state = unsafe { (self.api().resource_new)(self.raw, type_, out.as_mut_ptr()) };
        // The VM sets OUT in every case (to Void when it refuses).
        let term = self.term(unsafe { out.assume_init() });
        (term, if state.is_null() { None } else { Some(state) })
    }

    /// Fails the call with `message` once it returns. The first failure of a call wins.
    pub fn raise(self, message: &str) -> Term<'a> {
        // The VM copies a NUL-terminated message: cut it at a NUL inside, which C would read as its end anyway.
        let text = message.split('\0').next().unwrap_or("");
        let mut owned = Vec::with_capacity(text.len() + 1);
        owned.extend_from_slice(text.as_bytes());
        owned.push(0);
        self.term(unsafe { (self.api().raise)(self.raw, owned.as_ptr() as *const c_char) })
    }
}

/// The raw terms of `terms`, on the stack (`an_term` is plain data; the collector scans the stack).
fn raw_terms<'a>(terms: &[Term<'a>]) -> Vec<sys::an_term> {
    // A short Vec of raw terms lives only during the VM call that copies it, while `terms` (the caller's slice, on
    // its stack) still holds every one of them, so the collector sees each term through that slice.
    terms.iter().map(|t| t.raw).collect()
}

impl<'a> Term<'a> {
    /// # Safety
    ///
    /// `raw` is a term of the call of `env`.
    pub unsafe fn from_raw(env: Env<'a>, raw: sys::an_term) -> Self {
        Term { raw, env }
    }

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

    /// The text of a String, borrowed for the call; `None` for another term or for bytes that are not UTF-8.
    pub fn get_str(self) -> Option<&'a str> {
        let mut data = ptr::null();
        let mut len = 0;
        if !unsafe { (self.api().get_string)(self.e(), self.raw, &mut data, &mut len) } {
            return None;
        }
        core::str::from_utf8(unsafe { slice(data as *const u8, len) }).ok()
    }

    /// The data of a Bytes, borrowed for the call.
    pub fn get_bytes(self) -> Option<&'a [u8]> {
        let mut data = ptr::null();
        let mut len = 0;
        unsafe { (self.api().get_bytes)(self.e(), self.raw, &mut data, &mut len) }.then(|| unsafe { slice(data, len) })
    }

    /// The items of a List, in order, and their count.
    pub fn list_items(self) -> Option<ListItems<'a>> {
        let mut cursor = MaybeUninit::<sys::an_list_cursor>::uninit();
        let mut len = 0;
        unsafe { (self.api().list_cursor)(self.e(), self.raw, cursor.as_mut_ptr(), &mut len) }.then(|| ListItems {
            cursor: unsafe { cursor.assume_init() },
            len,
            env: self.env,
        })
    }

    /// The pairs of a Map, in insertion order, and their count.
    pub fn map_pairs(self) -> Option<MapPairs<'a>> {
        let mut cursor = MaybeUninit::<sys::an_map_cursor>::uninit();
        let mut len = 0;
        unsafe { (self.api().map_cursor)(self.e(), self.raw, cursor.as_mut_ptr(), &mut len) }.then(|| MapPairs {
            cursor: unsafe { cursor.assume_init() },
            len,
            env: self.env,
        })
    }

    /// An Optional as `Some(Some(value))` or `Some(None)`; `None` for another term.
    pub fn get_optional(self) -> Option<Option<Term<'a>>> {
        let mut some = false;
        let mut value = self.raw;
        unsafe { (self.api().get_optional)(self.e(), self.raw, &mut some, &mut value) }
            .then(|| some.then(|| self.env.term(value)))
    }

    /// A Result as `Ok(value)` or `Err(message)`, the message a String term.
    pub fn get_result(self) -> Option<Result<Term<'a>, Term<'a>>> {
        let mut ok = false;
        let mut value = self.raw;
        unsafe { (self.api().get_result)(self.e(), self.raw, &mut ok, &mut value) }.then(|| {
            let value = self.env.term(value);
            if ok { Ok(value) } else { Err(value) }
        })
    }

    /// The field `field` of a struct of row `type_`.
    pub fn get_field(self, type_: u32, field: u32) -> Option<Term<'a>> {
        let mut out = self.raw;
        unsafe { (self.api().get_field)(self.e(), self.raw, type_, field, &mut out) }.then(|| self.env.term(out))
    }

    /// The variant of an enum of row `type_`.
    pub fn get_variant(self, type_: u32) -> Option<u32> {
        let mut variant = 0;
        unsafe { (self.api().get_variant)(self.e(), self.raw, type_, &mut variant) }.then_some(variant)
    }

    /// The payload `k` of the variant of an enum of row `type_`.
    pub fn get_payload(self, type_: u32, k: u32) -> Option<Term<'a>> {
        let mut out = self.raw;
        unsafe { (self.api().get_payload)(self.e(), self.raw, type_, k, &mut out) }.then(|| self.env.term(out))
    }

    /// The state of a resource of row `type_` that is an argument of the call.
    pub fn get_resource(self, type_: u32) -> Option<*mut c_void> {
        let mut state = ptr::null_mut();
        unsafe { (self.api().get_resource)(self.e(), self.raw, type_, &mut state) }.then_some(state)
    }
}

/// A slice the VM gave for the call; an empty one may come with a null pointer, which a Rust slice cannot have.
unsafe fn slice<'a>(data: *const u8, len: usize) -> &'a [u8] {
    if len == 0 {
        &[]
    } else {
        unsafe { core::slice::from_raw_parts(data, len) }
    }
}

/// The items of a List, through its cursor.
pub struct ListItems<'a> {
    cursor: sys::an_list_cursor,
    len: usize,
    env: Env<'a>,
}

impl<'a> ListItems<'a> {
    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }
}

impl<'a> Iterator for ListItems<'a> {
    type Item = Term<'a>;

    fn next(&mut self) -> Option<Term<'a>> {
        let mut item = MaybeUninit::<sys::an_term>::uninit();
        let env = self.env;
        unsafe { (env.api().list_next)(env.raw, &mut self.cursor, item.as_mut_ptr()) }
            .then(|| env.term(unsafe { item.assume_init() }))
    }
}

/// The pairs of a Map, through its cursor.
pub struct MapPairs<'a> {
    cursor: sys::an_map_cursor,
    len: usize,
    env: Env<'a>,
}

impl<'a> MapPairs<'a> {
    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }
}

impl<'a> Iterator for MapPairs<'a> {
    type Item = (Term<'a>, Term<'a>);

    fn next(&mut self) -> Option<(Term<'a>, Term<'a>)> {
        let mut key = MaybeUninit::<sys::an_term>::uninit();
        let mut value = MaybeUninit::<sys::an_term>::uninit();
        let env = self.env;
        unsafe { (env.api().map_next)(env.raw, &mut self.cursor, key.as_mut_ptr(), value.as_mut_ptr()) }
            .then(|| unsafe { (env.term(key.assume_init()), env.term(value.assume_init())) })
    }
}
