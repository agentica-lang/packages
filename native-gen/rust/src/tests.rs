//! `call`, `Env` and `Term` on the mock VM: what a constructor makes, the getter of its kind reads back.

use crate::mock::{MockEnv, V};
use crate::*;

/// The result of a call of `body` in `mode` with `args`, or its failure.
fn run(
    mock: &MockEnv,
    mode: Mode,
    args: Vec<V>,
    body: impl for<'a> FnOnce(Env<'a>, Args<'a>) -> Term<'a>,
) -> Result<V, String> {
    let argv: Vec<sys::an_term> = args.into_iter().map(|v| mock.put(v)).collect();
    // SAFETY: the mock env lives for the call, with ARGC arguments at ARGV.
    let result = unsafe { call(mock.raw(), argv.len() as i32, argv.as_ptr(), mode, body) };
    match mock.failure.borrow().clone() {
        Some(message) => Err(message),
        None => Ok(mock.get(result)),
    }
}

fn short(args: Vec<V>, body: impl for<'a> FnOnce(Env<'a>, Args<'a>) -> Term<'a>) -> Result<V, String> {
    run(&MockEnv::new(false), Mode::Short, args, body)
}

#[test]
fn each_scalar_string_and_bytes_reads_back_and_other_getters_refuse_it() {
    let result = short(vec![], |env, _| {
        assert_eq!(env.int(i64::MIN).get_int(), Some(i64::MIN));
        assert_eq!(env.float(-2.5).get_float(), Some(-2.5));
        assert_eq!(env.bool(true).get_bool(), Some(true));
        assert_eq!(env.string("héllo").get_str(), Some("héllo"));
        assert_eq!(env.string("").get_str(), Some(""));
        assert_eq!(env.bytes(&[0, 255]).get_bytes(), Some(&[0u8, 255][..]));
        assert_eq!(env.bytes_with(3, |b| b.copy_from_slice(b"abc")).get_bytes(), Some(&b"abc"[..]));
        assert_eq!(env.int(1).get_str(), None);
        assert_eq!(env.string("1").get_int(), None);
        assert_eq!(env.void().get_bool(), None);
        env.list_of(&[env.int(1), env.int(2)])
    });
    assert_eq!(result, Ok(V::List(vec![V::Int(1), V::Int(2)])));
}

#[test]
fn a_list_is_walked_in_its_order_through_a_cursor_in_the_walk() {
    let result = short(vec![V::List(vec![V::Int(1), V::Int(2), V::Int(3)])], |env, args| {
        let list = args.get(0).unwrap();
        let read = list.list_items(|items| {
            assert_eq!(items.len(), 3);
            let all: Vec<_> = items.by_ref().map(|t| t.get_int().unwrap()).collect();
            assert!(items.next().is_none());
            all
        });
        assert_eq!(read, Some(vec![1, 2, 3]));
        assert!(env.int(1).list_items(|_| ()).is_none());
        // Items are parts of an argument, so a Vec may keep them for the call.
        let mut kept: Vec<Term> = list.list_items(|items| items.collect()).unwrap();
        kept.reverse();
        env.list(kept)
    });
    assert_eq!(result, Ok(V::List(vec![V::Int(3), V::Int(2), V::Int(1)])));
}

#[test]
fn a_short_call_roots_each_term_it_makes_and_a_dirty_one_none() {
    let mock = MockEnv::new(false);
    let result = run(&mock, Mode::Short, vec![], |env, _| {
        assert_eq!(env.mode(), Mode::Short);
        // Terms kept on the heap: each is in the root list, so the collector keeps it.
        let kept: Vec<Term> = (0..3).map(|n| env.int(n)).collect();
        env.list(kept)
    });
    assert_eq!(result, Ok(V::List(vec![V::Int(0), V::Int(1), V::Int(2)])));
    assert_eq!(mock.roots(), Some(4));

    let mock = MockEnv::new(true);
    let result = run(&mock, Mode::Dirty, vec![V::Int(7)], |env, args| {
        assert_eq!(env.mode(), Mode::Dirty);
        assert_eq!(args.get(0).unwrap().get_int(), Some(7));
        let made = env.string("staged");
        assert!(made.get_str().is_none());
        made
    });
    assert_eq!(result, Ok(V::Str(b"staged".to_vec())));
    assert_eq!(mock.roots(), None);
}

#[test]
fn the_first_failure_of_a_call_wins() {
    assert_eq!(short(vec![], |env, _| env.raise("bad\0hidden")), Err("bad".to_string()));
    let failed = short(vec![], |env, _| {
        env.badarg(1);
        env.raise("second")
    });
    assert_eq!(failed, Err("argument 2 is not valid".to_string()));
}
