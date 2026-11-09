//! `call`, `Env` and `Term` on the mock VM: what a constructor makes, the getter of its kind reads back.

use crate::mock::{MockEnv, V};
use crate::*;

/// The arities of the mock's type table (mock::TYPES).
fn types() -> Vec<Arity> {
    vec![Arity::Struct(2), Arity::Enum(vec![0, 1])]
}

/// The result of a call of `body` in `mode` with `args`, or its failure.
fn run(
    mock: &MockEnv,
    mode: Mode,
    args: Vec<V>,
    body: impl for<'a> FnOnce(Env<'a>, Args<'a>) -> Term<'a>,
) -> Result<V, String> {
    let argv: Vec<sys::an_term> = args.into_iter().map(|v| mock.put(v)).collect();
    // SAFETY: the mock env lives for the call, with ARGC arguments at ARGV.
    let result = unsafe { call(mock.raw(), argv.len() as i32, argv.as_ptr(), mode, &types(), body) };
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
fn a_list_and_a_map_are_walked_in_their_order() {
    let named = V::Map(vec![(V::Str(b"q".to_vec()), V::Int(1)), (V::Str(b"p".to_vec()), V::Int(2))]);
    let result = short(vec![V::List(vec![V::Int(1), V::Int(2), V::Int(3)]), named], |env, args| {
        let list = args.get(0).unwrap();
        let read = list.list_items(|items| {
            assert_eq!(items.len(), 3);
            let all: Vec<_> = items.by_ref().map(|t| t.get_int().unwrap()).collect();
            assert!(items.next().is_none());
            all
        });
        assert_eq!(read, Some(vec![1, 2, 3]));
        let map = args.get(1).unwrap();
        let pairs = map.map_pairs(|pairs| pairs.map(|(k, v)| (k.get_str().unwrap(), v.get_int().unwrap())).collect());
        assert_eq!(pairs, Some(vec![("q", 1), ("p", 2)]));
        assert_eq!(map.map_get(env.string("p")).and_then(Term::get_int), Some(2));
        assert!(map.map_get(env.string("z")).is_none());
        assert!(list.map_pairs(|_| ()).is_none());
        assert!(map.list_items(|_| ()).is_none());
        env.map([(env.string("b"), env.int(1)), (env.string("a"), env.int(2)), (env.string("b"), env.int(3))])
    });
    let b = || V::Str(b"b".to_vec());
    assert_eq!(result, Ok(V::Map(vec![(b(), V::Int(3)), (V::Str(b"a".to_vec()), V::Int(2))])));
}

#[test]
fn an_optional_and_a_result_give_their_value() {
    let result = short(vec![], |env, _| {
        assert_eq!(env.some(env.int(4)).get_optional().unwrap().unwrap().get_int(), Some(4));
        assert!(env.none().get_optional().unwrap().is_none());
        assert_eq!(env.ok(env.int(3)).get_result().unwrap().unwrap().get_int(), Some(3));
        assert_eq!(env.error("no").get_result().unwrap().unwrap_err().get_str(), Some("no"));
        assert!(env.int(1).get_optional().is_none());
        assert!(env.int(1).get_result().is_none());
        env.void()
    });
    assert_eq!(result, Ok(V::Void));
}

#[test]
fn a_struct_and_an_enum_give_their_parts_for_their_row_only() {
    let result = short(vec![], |env, _| {
        let point = env.make_struct(0, &[env.int(1), env.int(2)]);
        assert_eq!(point.get_field(0, 1).unwrap().get_int(), Some(2));
        assert!(point.get_field(1, 0).is_none());
        assert!(point.get_field(0, 2).is_none());
        let circle = env.make_enum(1, 1, &[point]);
        assert_eq!(circle.get_variant(1), Some(1));
        assert_eq!(circle.get_payload(1, 0).unwrap().get_field(0, 0).unwrap().get_int(), Some(1));
        assert_eq!(env.make_enum(1, 0, &[]).get_variant(1), Some(0));
        assert!(circle.get_variant(0).is_none());
        circle
    });
    let point = V::Struct(0, vec![V::Int(1), V::Int(2)]);
    assert_eq!(result, Ok(V::Enum(1, 1, vec![point])));
}

// The VM reads as many terms as the row takes, so another count must never reach it.
#[test]
fn a_struct_or_variant_of_another_arity_fails_the_call_before_the_vm_reads_it() {
    fn fails(body: for<'a> fn(Env<'a>) -> Term<'a>) -> String {
        short(vec![], |env, _| body(env)).unwrap_err()
    }
    assert!(fails(|env| env.make_struct(0, &[])).starts_with("make_struct: row 0"));
    assert!(fails(|env| env.make_struct(1, &[env.int(1), env.int(2)])).starts_with("make_struct: row 1"));
    assert!(fails(|env| env.make_enum(1, 1, &[])).starts_with("make_enum: row 1 has no variant 1"));
    assert!(fails(|env| env.make_enum(1, 2, &[])).starts_with("make_enum: row 1 has no variant 2"));
    assert!(fails(|env| env.make_enum(0, 0, &[])).starts_with("make_enum: row 0"));
    assert!(fails(|env| env.map([(env.bool(true), env.int(1))])).contains("a Map key"));
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
        let made = env.some(env.int(1));
        assert!(made.get_optional().is_none());
        made
    });
    assert_eq!(result, Ok(V::Some(Box::new(V::Int(1)))));
    assert_eq!(mock.roots(), None);
}

#[test]
fn a_resource_gives_its_state_only_as_an_argument() {
    let mock = MockEnv::new(false);
    let argument = run(&mock, Mode::Short, vec![], |env, _| env.resource_new(0).0).unwrap();
    let state = mock.states.borrow()[0].1;
    let result = run(&mock, Mode::Short, vec![argument], |env, args| {
        assert_eq!(args.get(0).unwrap().get_resource(0), Some(state));
        assert!(args.get(0).unwrap().get_resource(1).is_none());
        let (made, made_state) = env.resource_new(0);
        assert!(made_state.is_some());
        assert!(made.get_resource(0).is_none());
        env.void()
    });
    assert_eq!(result, Ok(V::Void));

    let refused = short(vec![], |env, _| {
        let (term, state) = env.resource_new(5);
        assert!(state.is_none());
        term
    });
    assert_eq!(refused, Err("not a resource row".to_string()));
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
