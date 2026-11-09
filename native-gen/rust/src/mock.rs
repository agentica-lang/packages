//! A VM for the unit tests: an `an_api` over a table of plain values, enough to read and make every kind of term.
//! The real VM runs in the features of native-gen.

use core::ffi::{c_char, c_int, c_void};
use std::cell::RefCell;

use crate::Arity;
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
    Map(Vec<(V, V)>),
    None,
    Some(Box<V>),
    Ok(Box<V>),
    Err(String),
    Struct(u32, Vec<V>),
    Enum(u32, u32, Vec<V>),
    Resource(u32, *mut c_void),
}

/// The type table of the mock module: row 0 a struct of two fields (Point), row 1 an enum whose variant 0 has no
/// payload and variant 1 one (Shape). It has one resource row.
pub const TYPES: &[Arity] = &[Arity::Struct(2), Arity::Enum(&[0, 1])];
pub const RESOURCE_ROWS: u32 = 1;

/// The env of one mock call. It starts with the table pointer, as the VM's does.
#[repr(C)]
pub struct MockEnv {
    api: *const an_api,
    // Each value, and whether it is staged: a dirty call stages what its constructors make, except the values that
    // need no memory (the test's own values are arguments).
    values: RefCell<Vec<(V, bool)>>,
    dirty: bool,
    pub failure: RefCell<Option<String>>,
    /// The states that resource_new gave: (row, state), for the free functions of a test.
    pub states: RefCell<Vec<(u32, *mut c_void)>>,
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
            states: RefCell::new(Vec::new()),
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

    fn push(&self, v: V, staged: bool) -> an_term {
        let mut values = self.values.borrow_mut();
        values.push((v, staged));
        an_term { opaque: [values.len() as u64 - 1, 0] }
    }

    pub fn get(&self, t: an_term) -> V {
        self.values.borrow()[t.opaque[0] as usize].0.clone()
    }

    /// Whether a getter may read `t`: a dirty call refuses the terms that it staged.
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

impl Drop for MockEnv {
    fn drop(&mut self) {
        for (_, state) in self.states.borrow_mut().drain(..) {
            drop(unsafe { Box::from_raw(state as *mut u64) });
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

/// A value that a constructor of the call made. As in the VM, a scalar, Void, none and a variant without a payload
/// need no memory, so a dirty call does not stage them and its getters read them.
fn made(e: *mut an_env, v: V) -> an_term {
    let staged = match &v {
        V::Int(_) | V::Float(_) | V::Bool(_) | V::Void | V::None => false,
        V::Enum(_, _, payload) => !payload.is_empty(),
        _ => true,
    };
    me(e).push(v, staged)
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
    let staged = me(e).values.borrow()[t.opaque[0] as usize].1;
    me(e).push(v, staged)
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
/// A key is an Int, a String or a Bytes; another fails the call.
fn key_kind(e: *mut an_env, key: &V) -> bool {
    let ok = matches!(key, V::Int(_) | V::Str(_) | V::Bytes(_));
    if !ok {
        fail(e, "a Map key is an Int, a String or a Bytes".into());
    }
    ok
}
unsafe extern "C" fn map_from(e: *mut an_env, keys: *const an_term, values: *const an_term, n: usize) -> an_term {
    // As the VM does: each pair put in order, so a later one of a key replaces the earlier.
    let mut pairs: Vec<(V, V)> = Vec::new();
    for (key, value) in values_at(e, keys, n).into_iter().zip(values_at(e, values, n)) {
        if !key_kind(e, &key) {
            return made(e, V::Void);
        }
        match pairs.iter_mut().find(|(k, _)| *k == key) {
            Some(pair) => pair.1 = value,
            None => pairs.push((key, value)),
        }
    }
    made(e, V::Map(pairs))
}
unsafe extern "C" fn map_put(e: *mut an_env, map: an_term, key: an_term, value: an_term) -> an_term {
    let V::Map(mut pairs) = me(e).get(map) else {
        return fail(e, "map_put of a non-map".into());
    };
    let (key, value) = (me(e).get(key), me(e).get(value));
    if !key_kind(e, &key) {
        return made(e, V::Void);
    }
    match pairs.iter_mut().find(|(k, _)| *k == key) {
        Some(pair) => pair.1 = value,
        None => pairs.push((key, value)),
    }
    made(e, V::Map(pairs))
}
unsafe extern "C" fn map_get(e: *mut an_env, map: an_term, key: an_term, value: *mut an_term) -> bool {
    if !me(e).readable(map) {
        return false;
    }
    let (V::Map(pairs), key) = (me(e).get(map), me(e).get(key)) else {
        return false;
    };
    let Some((_, v)) = pairs.into_iter().find(|(k, _)| *k == key) else {
        return false;
    };
    unsafe { *value = part(e, map, v) };
    true
}
unsafe extern "C" fn map_cursor(e: *mut an_env, t: an_term, c: *mut an_map_cursor, len: *mut usize) -> bool {
    if !me(e).readable(t) {
        return false;
    }
    let V::Map(pairs) = me(e).get(t) else { return false };
    unsafe { ((*c).opaque[0], (*c).opaque[1], *len) = (t.opaque[0], 0, pairs.len()) };
    true
}
unsafe extern "C" fn map_next(e: *mut an_env, c: *mut an_map_cursor, key: *mut an_term, value: *mut an_term) -> bool {
    let (map, at) = unsafe { ((*c).opaque[0], (*c).opaque[1]) };
    let t = an_term { opaque: [map, 0] };
    let V::Map(pairs) = me(e).get(t) else { return false };
    let Some((k, v)) = pairs.get(at as usize) else {
        return false;
    };
    unsafe { (*key, *value, (*c).opaque[1]) = (part(e, t, k.clone()), part(e, t, v.clone()), at + 1) };
    true
}
unsafe extern "C" fn make_none(e: *mut an_env) -> an_term {
    made(e, V::None)
}
unsafe extern "C" fn make_some(e: *mut an_env, value: an_term) -> an_term {
    made(e, V::Some(Box::new(me(e).get(value))))
}
unsafe extern "C" fn get_optional(e: *mut an_env, t: an_term, some: *mut bool, value: *mut an_term) -> bool {
    if !me(e).readable(t) {
        return false;
    }
    match me(e).get(t) {
        V::None => unsafe { *some = false },
        V::Some(v) => unsafe { (*some, *value) = (true, part(e, t, *v)) },
        _ => return false,
    }
    true
}
unsafe extern "C" fn make_ok(e: *mut an_env, value: an_term) -> an_term {
    made(e, V::Ok(Box::new(me(e).get(value))))
}
unsafe extern "C" fn make_error(e: *mut an_env, message: *const c_char, len: usize) -> an_term {
    let text = String::from_utf8_lossy(unsafe { bytes(message as *const u8, len) }).into_owned();
    made(e, V::Err(text))
}
unsafe extern "C" fn get_result(e: *mut an_env, t: an_term, ok: *mut bool, value: *mut an_term) -> bool {
    if !me(e).readable(t) {
        return false;
    }
    match me(e).get(t) {
        V::Ok(v) => unsafe { (*ok, *value) = (true, part(e, t, *v)) },
        V::Err(m) => unsafe { (*ok, *value) = (false, part(e, t, V::Str(m.into_bytes()))) },
        _ => return false,
    }
    true
}
unsafe extern "C" fn raise(e: *mut an_env, message: *const c_char) -> an_term {
    let text = unsafe { std::ffi::CStr::from_ptr(message) }.to_string_lossy().into_owned();
    fail(e, text)
}
unsafe extern "C" fn badarg(e: *mut an_env, index: c_int) -> an_term {
    fail(e, format!("argument {} is not valid", index + 1))
}
// The constructors read as many terms as the row takes, as the VM does: the test fails if Env passed fewer.
unsafe extern "C" fn make_struct(e: *mut an_env, type_: u32, fields: *const an_term) -> an_term {
    let Some(&Arity::Struct(n)) = TYPES.get(type_ as usize) else {
        return fail(e, "not a struct row".into());
    };
    made(e, V::Struct(type_, values_at(e, fields, n)))
}
unsafe extern "C" fn get_field(e: *mut an_env, t: an_term, type_: u32, field: u32, out: *mut an_term) -> bool {
    if !me(e).readable(t) {
        return false;
    }
    let V::Struct(row, fields) = me(e).get(t) else {
        return false;
    };
    let Some(v) = fields.get(field as usize).filter(|_| row == type_) else {
        return false;
    };
    unsafe { *out = part(e, t, v.clone()) };
    true
}
unsafe extern "C" fn make_enum(e: *mut an_env, type_: u32, variant: u32, payload: *const an_term) -> an_term {
    let Some(&n) = TYPES.get(type_ as usize).and_then(|row| match row {
        Arity::Enum(variants) => variants.get(variant as usize),
        Arity::Struct(_) => None,
    }) else {
        return fail(e, "not a variant of an enum row".into());
    };
    assert!(n == 0 || !payload.is_null(), "a missing payload");
    made(e, V::Enum(type_, variant, values_at(e, payload, n)))
}
unsafe extern "C" fn get_variant(e: *mut an_env, t: an_term, type_: u32, variant: *mut u32) -> bool {
    read(e, t, variant, |v| match v {
        V::Enum(row, variant, _) if row == type_ => Some(variant),
        _ => None,
    })
}
unsafe extern "C" fn get_payload(e: *mut an_env, t: an_term, type_: u32, k: u32, out: *mut an_term) -> bool {
    if !me(e).readable(t) {
        return false;
    }
    let V::Enum(row, _, payload) = me(e).get(t) else {
        return false;
    };
    let Some(v) = payload.get(k as usize).filter(|_| row == type_) else {
        return false;
    };
    unsafe { *out = part(e, t, v.clone()) };
    true
}
unsafe extern "C" fn resource_new(e: *mut an_env, type_: u32, out: *mut an_term) -> *mut c_void {
    if type_ >= RESOURCE_ROWS {
        unsafe { *out = fail(e, "not a resource row".into()) };
        return core::ptr::null_mut();
    }
    let state = Box::into_raw(Box::new(0u64)) as *mut c_void;
    me(e).states.borrow_mut().push((type_, state));
    unsafe { *out = made(e, V::Resource(type_, state)) };
    state
}
unsafe extern "C" fn get_resource(e: *mut an_env, t: an_term, type_: u32, state: *mut *mut c_void) -> bool {
    // A resource that the call made is never an argument of it.
    if me(e).values.borrow()[t.opaque[0] as usize].1 {
        return false;
    }
    read(e, t, state, |v| match v {
        V::Resource(row, state) if row == type_ => Some(state),
        _ => None,
    })
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
