//! The functions of check.agc on `call`, `Env` and `Term`, with tables written by hand.

use core::ffi::c_int;
use core::ptr;

use agentica_native::{Arity, Encoder, Mode, Term, call, sys};

/// Point, the one row of the type table: kept by hand in step with TYPE_ROWS below, row for row.
static TYPES: &[Arity] = &[Arity::Struct(2)];

/// `n` Strings, kept in a Vec of terms until the List is built: the root list of the call keeps them alive while
/// each new String may start a collection.
unsafe extern "C" fn strings(env: *mut sys::an_env, argc: c_int, argv: *const sys::an_term) -> sys::an_term {
    // SAFETY (each function): the VM passes its own env and arguments, and the mode is the one of the table.
    unsafe {
        call(env, argc, argv, Mode::Short, TYPES, |env, args| {
            let n = args.get(0).and_then(Term::get_int).unwrap_or(0);
            let kept: Vec<Term> =
                (0..n).map(|k| env.string(&format!("a string long enough to live on the heap {k}"))).collect();
            env.list(kept)
        })
    }
}

/// The same in a dirty call: the Strings are staged in the VM's memory for the call, not in the collector's, so they
/// come back whole while the calling scheduler allocates and collects meanwhile.
unsafe extern "C" fn staged_strings(env: *mut sys::an_env, argc: c_int, argv: *const sys::an_term) -> sys::an_term {
    unsafe {
        call(env, argc, argv, Mode::Dirty, TYPES, |env, args| {
            let n = args.get(0).and_then(Term::get_int).unwrap_or(0);
            let kept: Vec<Term> =
                (0..n).map(|k| env.string(&format!("a string long enough to live on the heap {k}"))).collect();
            env.list(kept)
        })
    }
}

/// The Map from each of `0..n` to its square, made in one map_from past the stack buffer of Env::map.
unsafe extern "C" fn squares(env: *mut sys::an_env, argc: c_int, argv: *const sys::an_term) -> sys::an_term {
    unsafe { call(env, argc, argv, Mode::Short, TYPES, |env, args| square_map(env, args.get(0))) }
}

/// The same in a dirty call.
unsafe extern "C" fn staged_squares(env: *mut sys::an_env, argc: c_int, argv: *const sys::an_term) -> sys::an_term {
    unsafe { call(env, argc, argv, Mode::Dirty, TYPES, |env, args| square_map(env, args.get(0))) }
}

fn square_map<'a>(env: agentica_native::Env<'a>, n: Option<Term<'a>>) -> Term<'a> {
    let n = n.and_then(Term::get_int).unwrap_or(0);
    env.map((0..n).map(|k| (env.int(k), env.int(k * k))))
}

/// The Map from "label K" to K for each of `0..n`: String keys made in a loop, each kept only by the root list until
/// the Map is made.
unsafe extern "C" fn labels(env: *mut sys::an_env, argc: c_int, argv: *const sys::an_term) -> sys::an_term {
    unsafe {
        call(env, argc, argv, Mode::Short, TYPES, |env, args| {
            let n = args.get(0).and_then(Term::get_int).unwrap_or(0);
            let mut pairs = Vec::new();
            for k in 0..n {
                pairs.push((env.string(&format!("label {k}")), env.int(k)));
            }
            env.map(pairs)
        })
    }
}

unsafe extern "C" fn pairs(env: *mut sys::an_env, argc: c_int, argv: *const sys::an_term) -> sys::an_term {
    unsafe {
        call(env, argc, argv, Mode::Short, TYPES, |env, args| {
            let named = args.get(0).unwrap();
            let texts: Vec<Term> = named
                .map_pairs(|pairs| {
                    pairs
                        .map(|(k, v)| env.string(&format!("{}={}", k.get_str().unwrap(), v.get_int().unwrap())))
                        .collect()
                })
                .unwrap_or_default();
            env.list(texts)
        })
    }
}

unsafe extern "C" fn point(env: *mut sys::an_env, argc: c_int, argv: *const sys::an_term) -> sys::an_term {
    unsafe {
        call(env, argc, argv, Mode::Short, TYPES, |env, args| {
            env.make_struct(0, &[args.get(0).unwrap(), args.get(1).unwrap()])
        })
    }
}

unsafe extern "C" fn bad_point(env: *mut sys::an_env, argc: c_int, argv: *const sys::an_term) -> sys::an_term {
    unsafe { call(env, argc, argv, Mode::Short, TYPES, |env, _| env.make_struct(0, &[env.int(1)])) }
}

unsafe extern "C" fn sum_x(env: *mut sys::an_env, argc: c_int, argv: *const sys::an_term) -> sys::an_term {
    unsafe {
        call(env, argc, argv, Mode::Short, TYPES, |env, args| {
            let total = args
                .get(0)
                .unwrap()
                .list_items(|items| items.map(|p| p.get_field(0, 0).and_then(Term::get_int).unwrap()).sum::<i64>());
            env.int(total.unwrap())
        })
    }
}

unsafe extern "C" fn total(env: *mut sys::an_env, argc: c_int, argv: *const sys::an_term) -> sys::an_term {
    unsafe {
        call(env, argc, argv, Mode::Dirty, TYPES, |env, args| {
            let sum = args.get(0).unwrap().list_items(|items| items.map(|t| t.get_int().unwrap()).sum::<i64>());
            // A dirty call reads the arguments, not what it staged.
            assert!(env.string("staged").get_str().is_none());
            env.int(sum.unwrap())
        })
    }
}

unsafe extern "C" fn filled(env: *mut sys::an_env, argc: c_int, argv: *const sys::an_term) -> sys::an_term {
    unsafe {
        call(env, argc, argv, Mode::Short, TYPES, |env, args| {
            let n = args.get(0).and_then(Term::get_int).unwrap() as usize;
            env.bytes_with(n, |data| data.iter_mut().enumerate().for_each(|(k, b)| *b = k as u8))
        })
    }
}

unsafe extern "C" fn lookup(env: *mut sys::an_env, argc: c_int, argv: *const sys::an_term) -> sys::an_term {
    unsafe {
        call(env, argc, argv, Mode::Short, TYPES, |env, args| {
            match args.get(0).unwrap().map_get(args.get(1).unwrap()) {
                Some(value) => env.some(value),
                None => env.none(),
            }
        })
    }
}

/// The type of `echo_rows` and `echo_staged`: every codec of a collection, nested.
type Rows = Vec<Vec<(String, Option<Result<Vec<f64>, String>>)>>;

/// The rows decoded into Rust values and encoded again, in a short call.
unsafe extern "C" fn echo_rows(env: *mut sys::an_env, argc: c_int, argv: *const sys::an_term) -> sys::an_term {
    unsafe {
        call(env, argc, argv, Mode::Short, TYPES, |env, args| match args.decode::<Rows>(0) {
            Ok(rows) => rows.encode(env),
            Err(error) => env.raise(&error.to_string()),
        })
    }
}

/// The same in a dirty call.
unsafe extern "C" fn echo_staged(env: *mut sys::an_env, argc: c_int, argv: *const sys::an_term) -> sys::an_term {
    unsafe {
        call(env, argc, argv, Mode::Dirty, TYPES, |env, args| match args.decode::<Rows>(0) {
            Ok(rows) => rows.encode(env),
            Err(error) => env.raise(&error.to_string()),
        })
    }
}

/// The scalars, String and Bytes as one String, read with Args::decode (String and Bytes borrowed).
unsafe extern "C" fn describe(env: *mut sys::an_env, argc: c_int, argv: *const sys::an_term) -> sys::an_term {
    unsafe {
        call(env, argc, argv, Mode::Short, TYPES, |env, args| {
            let read = || -> Result<String, agentica_native::DecodeError> {
                let (n, x, flag) = (args.decode::<i64>(0)?, args.decode::<f64>(1)?, args.decode::<bool>(2)?);
                let (text, data) = (args.decode::<&str>(3)?, args.decode::<&[u8]>(4)?);
                Ok(format!("{n} {x} {flag} {text} {data:?}"))
            };
            match read() {
                Ok(text) => text.encode(env),
                Err(error) => env.raise(&error.to_string()),
            }
        })
    }
}

macro_rules! function {
    ($name:literal, $signature:literal, $fn_:ident, $flags:expr) => {
        sys::an_function { name: $name.as_ptr(), signature: $signature.as_ptr(), fn_: $fn_, flags: $flags }
    };
}

static FUNCTIONS: [sys::an_function; 15] = [
    function!(c"strings", c"(Int) -> List[String]", strings, sys::AN_SHORT),
    function!(
        c"echo_rows",
        c"(List[Map[String, Optional[Result[List[Float]]]]]) -> List[Map[String, Optional[Result[List[Float]]]]]",
        echo_rows,
        sys::AN_SHORT
    ),
    function!(
        c"echo_staged",
        c"(List[Map[String, Optional[Result[List[Float]]]]]) -> List[Map[String, Optional[Result[List[Float]]]]]",
        echo_staged,
        sys::AN_DIRTY
    ),
    function!(c"describe", c"(Int, Float, Bool, String, Bytes) -> String", describe, sys::AN_SHORT),
    function!(c"staged_strings", c"(Int) -> List[String]", staged_strings, sys::AN_DIRTY),
    function!(c"squares", c"(Int) -> Map[Int, Int]", squares, sys::AN_SHORT),
    function!(c"staged_squares", c"(Int) -> Map[Int, Int]", staged_squares, sys::AN_DIRTY),
    function!(c"labels", c"(Int) -> Map[String, Int]", labels, sys::AN_SHORT),
    function!(c"pairs", c"(Map[String, Int]) -> List[String]", pairs, sys::AN_SHORT),
    function!(c"point", c"(Int, Int) -> Point", point, sys::AN_SHORT),
    function!(c"bad_point", c"() -> Point", bad_point, sys::AN_SHORT),
    function!(c"sum_x", c"(List[Point]) -> Int", sum_x, sys::AN_SHORT),
    function!(c"total", c"(List[Int]) -> Int", total, sys::AN_DIRTY),
    function!(c"filled", c"(Int) -> Bytes", filled, sys::AN_SHORT),
    function!(c"lookup", c"(Map[String, Int], String) -> Optional[Int]", lookup, sys::AN_SHORT),
];

// Kept by hand in step with TYPES above.
static TYPE_ROWS: [sys::an_type; 1] =
    [sys::an_type { name: c"Point".as_ptr(), kind: sys::AN_STRUCT, shape: c"x: Int, y: Int".as_ptr() }];

static MODULE: sys::an_module = sys::an_module {
    major: sys::AN_API_MAJOR,
    minor: sys::AN_API_MINOR,
    size: size_of::<sys::an_module>() as u32,
    name: c"vm_check".as_ptr(),
    load: None,
    functions: FUNCTIONS.as_ptr(),
    function_count: FUNCTIONS.len() as u32,
    types: TYPE_ROWS.as_ptr(),
    type_count: TYPE_ROWS.len() as u32,
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
