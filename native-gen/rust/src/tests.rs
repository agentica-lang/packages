//! `Env` and `Term` on the mock VM: what a constructor makes, the getter of its kind reads back.

use crate::mock::{MockEnv, V};
use crate::*;

#[test]
fn each_scalar_string_and_bytes_reads_back_and_other_getters_refuse_it() {
    let mock = MockEnv::new();
    let env = unsafe { Env::from_raw(mock.raw()) };
    assert_eq!(env.int(i64::MIN).get_int(), Some(i64::MIN));
    assert_eq!(env.float(-2.5).get_float(), Some(-2.5));
    assert_eq!(env.bool(true).get_bool(), Some(true));
    assert_eq!(env.string("héllo").get_str(), Some("héllo"));
    assert_eq!(env.string("").get_str(), Some(""));
    assert_eq!(env.bytes(&[0, 255]).get_bytes(), Some(&[0u8, 255][..]));
    assert_eq!(env.int(1).get_str(), None);
    assert_eq!(env.string("1").get_int(), None);
    assert_eq!(env.void().get_bool(), None);
}

#[test]
fn a_list_and_a_map_read_back_in_their_order() {
    let mock = MockEnv::new();
    let env = unsafe { Env::from_raw(mock.raw()) };
    let list = env.list((1..=3).map(|n| env.int(n)));
    let items = list.list_items().unwrap();
    assert_eq!(items.len(), 3);
    assert_eq!(items.map(|t| t.get_int().unwrap()).collect::<Vec<_>>(), [1, 2, 3]);
    assert!(env.list([]).list_items().unwrap().is_empty());

    let map = env.map(["q", "p"].iter().zip(1..).map(|(k, v)| (env.string(k), env.int(v))));
    let pairs = map.map_pairs().unwrap();
    assert_eq!(pairs.len(), 2);
    let read: Vec<_> = pairs
        .map(|(k, v)| (k.get_str().unwrap(), v.get_int().unwrap()))
        .collect();
    assert_eq!(read, [("q", 1), ("p", 2)]);
    assert!(list.map_pairs().is_none());
    assert!(map.list_items().is_none());
}

#[test]
fn an_optional_and_a_result_give_their_value() {
    let mock = MockEnv::new();
    let env = unsafe { Env::from_raw(mock.raw()) };
    assert_eq!(env.some(env.int(4)).get_optional().unwrap().unwrap().get_int(), Some(4));
    assert!(env.none().get_optional().unwrap().is_none());
    assert_eq!(env.ok(env.int(3)).get_result().unwrap().unwrap().get_int(), Some(3));
    let error = env.error("no").get_result().unwrap().unwrap_err();
    assert_eq!(error.get_str(), Some("no"));
    assert!(env.int(1).get_optional().is_none());
    assert!(env.int(1).get_result().is_none());
}

#[test]
fn a_struct_and_an_enum_give_their_parts_for_their_row_only() {
    let mock = MockEnv::new();
    let env = unsafe { Env::from_raw(mock.raw()) };
    let point = env.make_struct(0, &[env.int(1), env.int(2)]);
    assert_eq!(point.get_field(0, 1).unwrap().get_int(), Some(2));
    assert!(point.get_field(1, 0).is_none());
    assert!(point.get_field(0, 2).is_none());
    let circle = env.make_enum(1, 1, &[point]);
    assert_eq!(circle.get_variant(1), Some(1));
    assert_eq!(
        circle.get_payload(1, 0).unwrap().get_field(0, 0).unwrap().get_int(),
        Some(1)
    );
    assert_eq!(env.make_enum(1, 0, &[]).get_variant(1), Some(0));
    assert!(circle.get_variant(0).is_none());
}

#[test]
fn a_resource_gives_its_state_and_a_raise_fails_the_call_once() {
    let mock = MockEnv::new();
    let env = unsafe { Env::from_raw(mock.raw()) };
    let (term, state) = env.resource_new(0);
    let state = state.unwrap();
    assert_eq!(term.get_resource(0), Some(state));
    assert!(term.get_resource(1).is_none());
    assert!(env.int(1).get_resource(0).is_none());

    assert_eq!(mock.get(env.raise("bad\0hidden").as_raw()), V::Void);
    env.raise("second");
    assert_eq!(mock.failure.borrow().as_deref(), Some("bad"));
}
