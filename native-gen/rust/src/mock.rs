//! A VM for the unit tests: an `an_api` over a table of plain values, enough to read and make every kind of term.
//! The real VM runs in the features of native-gen.

use core::ffi::{c_char, c_int, c_void};
use std::cell::RefCell;

use crate::sys::*;

#[derive(Clone, Debug, PartialEq)]
pub enum V {
    Int(i64),
    Float(f64),
    Bool(bool),
    Void,
    Str(Vec<u8>),
    Bytes(Vec<u8>),
    List(Vec<V>),
}

/// The env of one mock call. It starts with the table pointer, as the VM's does.
#[repr(C)]
pub struct MockEnv {
    api: *const an_api,
    // Each value, and whether a constructor of the call made it (the test's own values are arguments).
    values: RefCell<Vec<(V, bool)>>,
    dirty: bool,
    pub failure: RefCell<Option<String>>,
    // The List of the first builder begun: the root list of a short call.
    first_builder: RefCell<Option<u64>>,
}

impl MockEnv {
    /// The env of a call in `dirty` mode or not.
    pub fn new(dirty: bool) -> Box<MockEnv> {
        Box::new(MockEnv {
            api: &API,
            values: RefCell::new(Vec::new()),
            dirty,
            failure: RefCell::new(None),
            first_builder: RefCell::new(None),
        })
    }

    pub fn raw(&self) -> *mut an_env {
        self as *const MockEnv as *mut an_env
    }

    /// An argument of the call.
    pub fn put(&self, v: V) -> an_term {
        self.push(v, false)
    }

    fn push(&self, v: V, made: bool) -> an_term {
        let mut values = self.values.borrow_mut();
        values.push((v, made));
        an_term { opaque: [values.len() as u64 - 1, 0] }
    }

    pub fn get(&self, t: an_term) -> V {
        self.values.borrow()[t.opaque[0] as usize].0.clone()
    }

    /// Whether a getter may read `t`: a dirty call refuses the terms that it made.
    fn readable(&self, t: an_term) -> bool {
        !(self.dirty && self.values.borrow()[t.opaque[0] as usize].1)
    }

    /// How many terms the root list holds, when a builder was begun.
    pub fn roots(&self) -> Option<usize> {
        let list = (*self.first_builder.borrow())?;
        match self.get(an_term { opaque: [list, 0] }) {
            V::List(items) => Some(items.len()),
            _ => None,
        }
    }
}

fn me<'a>(e: *mut an_env) -> &'a MockEnv {
    unsafe { &*(e as *const MockEnv) }
}

fn fail(e: *mut an_env, message: String) -> an_term {
    me(e).failure.borrow_mut().get_or_insert(message);
    made(e, V::Void)
}

/// A value that a constructor of the call made.
fn made(e: *mut an_env, v: V) -> an_term {
    me(e).push(v, true)
}

unsafe fn bytes<'b>(data: *const u8, len: usize) -> &'b [u8] {
    if len == 0 { &[] } else { unsafe { core::slice::from_raw_parts(data, len) } }
}

/// Writes `out` when `v` is the value `pick` takes.
fn read<X>(e: *mut an_env, t: an_term, out: *mut X, pick: impl FnOnce(V) -> Option<X>) -> bool {
    if !me(e).readable(t) {
        return false;
    }
    match pick(me(e).get(t)) {
        Some(x) => {
            unsafe { *out = x };
            true
        }
        None => false,
    }
}

/// A part of `t` (an item, a field, a payload): readable when `t` is.
fn part(e: *mut an_env, t: an_term, v: V) -> an_term {
    let parent_made = me(e).values.borrow()[t.opaque[0] as usize].1;
    me(e).push(v, parent_made)
}

/// The values of `n` terms at `at`.
fn values_at(e: *mut an_env, at: *const an_term, n: usize) -> Vec<V> {
    (0..n).map(|k| me(e).get(unsafe { *at.add(k) })).collect()
}

unsafe extern "C" fn make_int(e: *mut an_env, n: i64) -> an_term {
    made(e, V::Int(n))
}
unsafe extern "C" fn get_int(e: *mut an_env, t: an_term, n: *mut i64) -> bool {
    read(e, t, n, |v| if let V::Int(n) = v { Some(n) } else { None })
}
unsafe extern "C" fn make_float(e: *mut an_env, x: f64) -> an_term {
    made(e, V::Float(x))
}
unsafe extern "C" fn get_float(e: *mut an_env, t: an_term, x: *mut f64) -> bool {
    read(e, t, x, |v| if let V::Float(x) = v { Some(x) } else { None })
}
unsafe extern "C" fn make_bool(e: *mut an_env, b: bool) -> an_term {
    made(e, V::Bool(b))
}
unsafe extern "C" fn get_bool(e: *mut an_env, t: an_term, b: *mut bool) -> bool {
    read(e, t, b, |v| if let V::Bool(b) = v { Some(b) } else { None })
}
unsafe extern "C" fn make_void(e: *mut an_env) -> an_term {
    made(e, V::Void)
}
unsafe extern "C" fn make_string(e: *mut an_env, data: *const c_char, len: usize) -> an_term {
    let text = unsafe { bytes(data as *const u8, len) }.to_vec();
    if std::str::from_utf8(&text).is_err() {
        return fail(e, "bad UTF-8".into());
    }
    made(e, V::Str(text))
}
// The data stays in the table of values, whose items never change once pushed: the pointer lasts as long as the env.
unsafe extern "C" fn get_string(e: *mut an_env, t: an_term, data: *mut *const c_char, len: *mut usize) -> bool {
    if !me(e).readable(t) {
        return false;
    }
    let values = me(e).values.borrow();
    let V::Str(s) = &values[t.opaque[0] as usize].0 else {
        return false;
    };
    unsafe { (*data, *len) = (s.as_ptr() as *const c_char, s.len()) };
    true
}
unsafe extern "C" fn make_bytes(e: *mut an_env, data: *const c_void, len: usize) -> an_term {
    made(e, V::Bytes(unsafe { bytes(data as *const u8, len) }.to_vec()))
}
unsafe extern "C" fn bytes_fill(e: *mut an_env, len: usize, data: *mut *mut u8) -> an_term {
    let t = made(e, V::Bytes(vec![0; len]));
    let mut values = me(e).values.borrow_mut();
    if let V::Bytes(b) = &mut values[t.opaque[0] as usize].0 {
        unsafe { *data = b.as_mut_ptr() };
    }
    t
}
unsafe extern "C" fn get_bytes(e: *mut an_env, t: an_term, data: *mut *const u8, len: *mut usize) -> bool {
    if !me(e).readable(t) {
        return false;
    }
    let values = me(e).values.borrow();
    let V::Bytes(s) = &values[t.opaque[0] as usize].0 else {
        return false;
    };
    unsafe { (*data, *len) = (s.as_ptr(), s.len()) };
    true
}
unsafe extern "C" fn make_list(e: *mut an_env, items: *const an_term, n: usize) -> an_term {
    made(e, V::List(values_at(e, items, n)))
}
// A builder and a cursor keep the index of their List in opaque[0], and a cursor its position in opaque[1].
unsafe extern "C" fn list_begin(e: *mut an_env, b: *mut an_list_builder, _hint: usize) {
    let t = made(e, V::List(Vec::new()));
    me(e).first_builder.borrow_mut().get_or_insert(t.opaque[0]);
    unsafe { (*b).opaque[0] = t.opaque[0] };
}
unsafe extern "C" fn list_push(e: *mut an_env, b: *mut an_list_builder, item: an_term) {
    let item = me(e).get(item);
    let mut values = me(e).values.borrow_mut();
    if let V::List(items) = &mut values[unsafe { (*b).opaque[0] } as usize].0 {
        items.push(item);
    }
}
unsafe extern "C" fn list_end(_e: *mut an_env, b: *mut an_list_builder) -> an_term {
    an_term { opaque: [unsafe { (*b).opaque[0] }, 0] }
}
unsafe extern "C" fn list_cursor(e: *mut an_env, t: an_term, c: *mut an_list_cursor, len: *mut usize) -> bool {
    if !me(e).readable(t) {
        return false;
    }
    let V::List(items) = me(e).get(t) else { return false };
    unsafe { ((*c).opaque[0], (*c).opaque[1], *len) = (t.opaque[0], 0, items.len()) };
    true
}
unsafe extern "C" fn list_next(e: *mut an_env, c: *mut an_list_cursor, item: *mut an_term) -> bool {
    let (list, at) = unsafe { ((*c).opaque[0], (*c).opaque[1]) };
    let t = an_term { opaque: [list, 0] };
    let V::List(items) = me(e).get(t) else { return false };
    let Some(v) = items.get(at as usize) else { return false };
    unsafe { (*item, (*c).opaque[1]) = (part(e, t, v.clone()), at + 1) };
    true
}
unsafe extern "C" fn raise(e: *mut an_env, message: *const c_char) -> an_term {
    let text = unsafe { std::ffi::CStr::from_ptr(message) }.to_string_lossy().into_owned();
    fail(e, text)
}
unsafe extern "C" fn badarg(e: *mut an_env, index: c_int) -> an_term {
    fail(e, format!("argument {} is not valid", index + 1))
}

// The parts of the API that the crate does not wrap yet: each fails the call.
unsafe extern "C" fn map_from(e: *mut an_env, _: *const an_term, _: *const an_term, _: usize) -> an_term {
    fail(e, "map_from".into())
}
unsafe extern "C" fn map_put(e: *mut an_env, _: an_term, _: an_term, _: an_term) -> an_term {
    fail(e, "map_put".into())
}
unsafe extern "C" fn map_get(_: *mut an_env, _: an_term, _: an_term, _: *mut an_term) -> bool {
    false
}
unsafe extern "C" fn map_cursor(_: *mut an_env, _: an_term, _: *mut an_map_cursor, _: *mut usize) -> bool {
    false
}
unsafe extern "C" fn map_next(_: *mut an_env, _: *mut an_map_cursor, _: *mut an_term, _: *mut an_term) -> bool {
    false
}
unsafe extern "C" fn make_none(e: *mut an_env) -> an_term {
    fail(e, "make_none".into())
}
unsafe extern "C" fn make_some(e: *mut an_env, _: an_term) -> an_term {
    fail(e, "make_some".into())
}
unsafe extern "C" fn get_optional(_: *mut an_env, _: an_term, _: *mut bool, _: *mut an_term) -> bool {
    false
}
unsafe extern "C" fn make_ok(e: *mut an_env, _: an_term) -> an_term {
    fail(e, "make_ok".into())
}
unsafe extern "C" fn make_error(e: *mut an_env, _: *const c_char, _: usize) -> an_term {
    fail(e, "make_error".into())
}
unsafe extern "C" fn get_result(_: *mut an_env, _: an_term, _: *mut bool, _: *mut an_term) -> bool {
    false
}
unsafe extern "C" fn make_struct(e: *mut an_env, _: u32, _: *const an_term) -> an_term {
    fail(e, "make_struct".into())
}
unsafe extern "C" fn get_field(_: *mut an_env, _: an_term, _: u32, _: u32, _: *mut an_term) -> bool {
    false
}
unsafe extern "C" fn make_enum(e: *mut an_env, _: u32, _: u32, _: *const an_term) -> an_term {
    fail(e, "make_enum".into())
}
unsafe extern "C" fn get_variant(_: *mut an_env, _: an_term, _: u32, _: *mut u32) -> bool {
    false
}
unsafe extern "C" fn get_payload(_: *mut an_env, _: an_term, _: u32, _: u32, _: *mut an_term) -> bool {
    false
}
unsafe extern "C" fn resource_new(e: *mut an_env, _: u32, out: *mut an_term) -> *mut c_void {
    unsafe { *out = fail(e, "resource_new".into()) };
    core::ptr::null_mut()
}
unsafe extern "C" fn get_resource(_: *mut an_env, _: an_term, _: u32, _: *mut *mut c_void) -> bool {
    false
}

static API: an_api = an_api {
    major: AN_API_MAJOR,
    minor: AN_API_MINOR,
    size: core::mem::size_of::<an_api>() as u32,
    make_int,
    get_int,
    make_float,
    get_float,
    make_bool,
    get_bool,
    make_void,
    make_string,
    get_string,
    make_bytes,
    bytes_fill,
    get_bytes,
    make_list,
    list_begin,
    list_push,
    list_end,
    list_cursor,
    list_next,
    map_from,
    map_put,
    map_get,
    map_cursor,
    map_next,
    make_none,
    make_some,
    get_optional,
    make_ok,
    make_error,
    get_result,
    raise,
    badarg,
    make_struct,
    get_field,
    make_enum,
    get_variant,
    get_payload,
    resource_new,
    get_resource,
};
