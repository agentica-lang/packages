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
    Map(Vec<(V, V)>),
    None,
    Some(Box<V>),
    Ok(Box<V>),
    Err(String),
    Struct(u32, Vec<V>),
    Enum(u32, u32, Vec<V>),
    Resource(u32, usize),
}

/// The env of one mock call. It starts with the table pointer, as the VM's does.
#[repr(C)]
pub struct MockEnv {
    api: *const an_api,
    values: RefCell<Vec<V>>,
    pub failure: RefCell<Option<String>>,
    /// The states that resource_new gave: (row, state), for the free functions of a test.
    pub states: RefCell<Vec<(u32, *mut c_void)>>,
}

impl MockEnv {
    pub fn new() -> Box<MockEnv> {
        Box::new(MockEnv {
            api: &API,
            values: RefCell::new(Vec::new()),
            failure: RefCell::new(None),
            states: RefCell::new(Vec::new()),
        })
    }

    pub fn raw(&self) -> *mut an_env {
        self as *const MockEnv as *mut an_env
    }

    pub fn put(&self, v: V) -> an_term {
        let mut values = self.values.borrow_mut();
        values.push(v);
        an_term {
            opaque: [values.len() as u64 - 1, 0],
        }
    }

    pub fn get(&self, t: an_term) -> V {
        self.values.borrow()[t.opaque[0] as usize].clone()
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
    me(e).put(V::Void)
}

unsafe fn bytes<'b>(data: *const u8, len: usize) -> &'b [u8] {
    if len == 0 {
        &[]
    } else {
        unsafe { core::slice::from_raw_parts(data, len) }
    }
}

/// Writes `out` when `v` is the value `pick` takes.
fn read<X>(e: *mut an_env, t: an_term, out: *mut X, pick: impl FnOnce(V) -> Option<X>) -> bool {
    match pick(me(e).get(t)) {
        Some(x) => {
            unsafe { *out = x };
            true
        }
        None => false,
    }
}

unsafe extern "C" fn make_int(e: *mut an_env, n: i64) -> an_term {
    me(e).put(V::Int(n))
}
unsafe extern "C" fn get_int(e: *mut an_env, t: an_term, n: *mut i64) -> bool {
    read(e, t, n, |v| if let V::Int(n) = v { Some(n) } else { None })
}
unsafe extern "C" fn make_float(e: *mut an_env, x: f64) -> an_term {
    me(e).put(V::Float(x))
}
unsafe extern "C" fn get_float(e: *mut an_env, t: an_term, x: *mut f64) -> bool {
    read(e, t, x, |v| if let V::Float(x) = v { Some(x) } else { None })
}
unsafe extern "C" fn make_bool(e: *mut an_env, b: bool) -> an_term {
    me(e).put(V::Bool(b))
}
unsafe extern "C" fn get_bool(e: *mut an_env, t: an_term, b: *mut bool) -> bool {
    read(e, t, b, |v| if let V::Bool(b) = v { Some(b) } else { None })
}
unsafe extern "C" fn make_void(e: *mut an_env) -> an_term {
    me(e).put(V::Void)
}
unsafe extern "C" fn make_string(e: *mut an_env, data: *const c_char, len: usize) -> an_term {
    me(e).put(V::Str(unsafe { bytes(data as *const u8, len) }.to_vec()))
}
// The data stays in the table of values, which only grows during a test: the pointer lasts as long as the env.
unsafe extern "C" fn get_string(e: *mut an_env, t: an_term, data: *mut *const c_char, len: *mut usize) -> bool {
    let values = me(e).values.borrow();
    let V::Str(s) = &values[t.opaque[0] as usize] else {
        return false;
    };
    unsafe { (*data, *len) = (s.as_ptr() as *const c_char, s.len()) };
    true
}
unsafe extern "C" fn make_bytes(e: *mut an_env, data: *const c_void, len: usize) -> an_term {
    me(e).put(V::Bytes(unsafe { bytes(data as *const u8, len) }.to_vec()))
}
unsafe extern "C" fn bytes_fill(e: *mut an_env, _len: usize, _data: *mut *mut u8) -> an_term {
    fail(e, "bytes_fill is not in the mock".into())
}
unsafe extern "C" fn get_bytes(e: *mut an_env, t: an_term, data: *mut *const u8, len: *mut usize) -> bool {
    let values = me(e).values.borrow();
    let V::Bytes(s) = &values[t.opaque[0] as usize] else {
        return false;
    };
    unsafe { (*data, *len) = (s.as_ptr(), s.len()) };
    true
}
unsafe extern "C" fn make_list(e: *mut an_env, items: *const an_term, n: usize) -> an_term {
    let items = (0..n).map(|k| me(e).get(unsafe { *items.add(k) })).collect();
    me(e).put(V::List(items))
}
// A builder and a cursor keep the index of their List in opaque[0], and a cursor its position in opaque[1].
unsafe extern "C" fn list_begin(e: *mut an_env, b: *mut an_list_builder, _hint: usize) {
    let t = me(e).put(V::List(Vec::new()));
    unsafe { (*b).opaque[0] = t.opaque[0] };
}
unsafe extern "C" fn list_push(e: *mut an_env, b: *mut an_list_builder, item: an_term) {
    let item = me(e).get(item);
    let mut values = me(e).values.borrow_mut();
    if let V::List(items) = &mut values[unsafe { (*b).opaque[0] } as usize] {
        items.push(item);
    }
}
unsafe extern "C" fn list_end(_e: *mut an_env, b: *mut an_list_builder) -> an_term {
    an_term {
        opaque: [unsafe { (*b).opaque[0] }, 0],
    }
}
unsafe extern "C" fn list_cursor(e: *mut an_env, t: an_term, c: *mut an_list_cursor, len: *mut usize) -> bool {
    let V::List(items) = me(e).get(t) else {
        return false;
    };
    unsafe {
        (*c).opaque[0] = t.opaque[0];
        (*c).opaque[1] = 0;
        *len = items.len();
    }
    true
}
unsafe extern "C" fn list_next(e: *mut an_env, c: *mut an_list_cursor, item: *mut an_term) -> bool {
    let (list, at) = unsafe { ((*c).opaque[0], (*c).opaque[1]) };
    let V::List(items) = me(e).get(an_term { opaque: [list, 0] }) else {
        return false;
    };
    let Some(v) = items.get(at as usize) else {
        return false;
    };
    unsafe {
        *item = me(e).put(v.clone());
        (*c).opaque[1] = at + 1;
    }
    true
}
unsafe extern "C" fn map_from(e: *mut an_env, keys: *const an_term, values: *const an_term, n: usize) -> an_term {
    let pairs = (0..n)
        .map(|k| unsafe { (me(e).get(*keys.add(k)), me(e).get(*values.add(k))) })
        .collect();
    me(e).put(V::Map(pairs))
}
unsafe extern "C" fn map_put(e: *mut an_env, map: an_term, key: an_term, value: an_term) -> an_term {
    let V::Map(mut pairs) = me(e).get(map) else {
        return fail(e, "map_put of a non-map".into());
    };
    let (key, value) = (me(e).get(key), me(e).get(value));
    match pairs.iter_mut().find(|(k, _)| *k == key) {
        Some(pair) => pair.1 = value,
        None => pairs.push((key, value)),
    }
    me(e).put(V::Map(pairs))
}
unsafe extern "C" fn map_get(_e: *mut an_env, _map: an_term, _key: an_term, _value: *mut an_term) -> bool {
    false
}
unsafe extern "C" fn map_cursor(e: *mut an_env, t: an_term, c: *mut an_map_cursor, len: *mut usize) -> bool {
    let V::Map(pairs) = me(e).get(t) else {
        return false;
    };
    unsafe {
        (*c).opaque[0] = t.opaque[0];
        (*c).opaque[1] = 0;
        *len = pairs.len();
    }
    true
}
unsafe extern "C" fn map_next(e: *mut an_env, c: *mut an_map_cursor, key: *mut an_term, value: *mut an_term) -> bool {
    let (map, at) = unsafe { ((*c).opaque[0], (*c).opaque[1]) };
    let V::Map(pairs) = me(e).get(an_term { opaque: [map, 0] }) else {
        return false;
    };
    let Some((k, v)) = pairs.get(at as usize) else {
        return false;
    };
    unsafe {
        *key = me(e).put(k.clone());
        *value = me(e).put(v.clone());
        (*c).opaque[1] = at + 1;
    }
    true
}
unsafe extern "C" fn make_none(e: *mut an_env) -> an_term {
    me(e).put(V::None)
}
unsafe extern "C" fn make_some(e: *mut an_env, value: an_term) -> an_term {
    me(e).put(V::Some(Box::new(me(e).get(value))))
}
unsafe extern "C" fn get_optional(e: *mut an_env, t: an_term, some: *mut bool, value: *mut an_term) -> bool {
    match me(e).get(t) {
        V::None => unsafe { *some = false },
        V::Some(v) => unsafe { (*some, *value) = (true, me(e).put(*v)) },
        _ => return false,
    }
    true
}
unsafe extern "C" fn make_ok(e: *mut an_env, value: an_term) -> an_term {
    me(e).put(V::Ok(Box::new(me(e).get(value))))
}
unsafe extern "C" fn make_error(e: *mut an_env, message: *const c_char, len: usize) -> an_term {
    let text = String::from_utf8_lossy(unsafe { bytes(message as *const u8, len) }).into_owned();
    me(e).put(V::Err(text))
}
unsafe extern "C" fn get_result(e: *mut an_env, t: an_term, ok: *mut bool, value: *mut an_term) -> bool {
    match me(e).get(t) {
        V::Ok(v) => unsafe { (*ok, *value) = (true, me(e).put(*v)) },
        V::Err(m) => unsafe { (*ok, *value) = (false, me(e).put(V::Str(m.into_bytes()))) },
        _ => return false,
    }
    true
}
unsafe extern "C" fn raise(e: *mut an_env, message: *const c_char) -> an_term {
    let text = unsafe { std::ffi::CStr::from_ptr(message) }
        .to_string_lossy()
        .into_owned();
    fail(e, text)
}
unsafe extern "C" fn badarg(e: *mut an_env, index: c_int) -> an_term {
    fail(e, format!("argument {} is not valid", index + 1))
}
unsafe extern "C" fn make_struct(e: *mut an_env, type_: u32, _fields: *const an_term) -> an_term {
    // The mock knows no shapes: the test's struct has two fields.
    let fields = (0..2).map(|k| me(e).get(unsafe { *_fields.add(k) })).collect();
    me(e).put(V::Struct(type_, fields))
}
unsafe extern "C" fn get_field(e: *mut an_env, t: an_term, type_: u32, field: u32, out: *mut an_term) -> bool {
    let V::Struct(row, fields) = me(e).get(t) else {
        return false;
    };
    let Some(v) = fields.get(field as usize).filter(|_| row == type_) else {
        return false;
    };
    unsafe { *out = me(e).put(v.clone()) };
    true
}
unsafe extern "C" fn make_enum(e: *mut an_env, type_: u32, variant: u32, payload: *const an_term) -> an_term {
    // The test's enum has one payload in variant 1 and none in variant 0.
    let payload = if variant == 1 {
        vec![me(e).get(unsafe { *payload })]
    } else {
        Vec::new()
    };
    me(e).put(V::Enum(type_, variant, payload))
}
unsafe extern "C" fn get_variant(e: *mut an_env, t: an_term, type_: u32, variant: *mut u32) -> bool {
    read(e, t, variant, |v| match v {
        V::Enum(row, variant, _) if row == type_ => Some(variant),
        _ => None,
    })
}
unsafe extern "C" fn get_payload(e: *mut an_env, t: an_term, type_: u32, k: u32, out: *mut an_term) -> bool {
    let V::Enum(row, _, payload) = me(e).get(t) else {
        return false;
    };
    let Some(v) = payload.get(k as usize).filter(|_| row == type_) else {
        return false;
    };
    unsafe { *out = me(e).put(v.clone()) };
    true
}
unsafe extern "C" fn resource_new(e: *mut an_env, type_: u32, out: *mut an_term) -> *mut c_void {
    let state = Box::into_raw(Box::new(0u64)) as *mut c_void;
    me(e).states.borrow_mut().push((type_, state));
    unsafe { *out = me(e).put(V::Resource(type_, state as usize)) };
    state
}
unsafe extern "C" fn get_resource(e: *mut an_env, t: an_term, type_: u32, state: *mut *mut c_void) -> bool {
    read(e, t, state, |v| match v {
        V::Resource(row, state) if row == type_ => Some(state as *mut c_void),
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
