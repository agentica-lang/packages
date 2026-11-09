//! `Decoder` and `Encoder` on the mock VM: what each encodes decodes back equal, and a bad part fails with its path.

use crate::mock::MockEnv;
use crate::mock::V;
use crate::tests::{dirty, short};
use crate::*;

/// The struct and enum of the mock's type table (row 0 and row 1), with the codecs that native-gen writes.
#[derive(Clone, Debug, PartialEq)]
struct Point {
    x: i64,
    y: i64,
}

#[derive(Clone, Debug, PartialEq)]
enum Shape {
    Dot,
    Circle(Point),
}

impl<'a> Decoder<'a> for Point {
    fn type_name() -> String {
        "Point".to_string()
    }

    fn decode(term: Term<'a>) -> Result<Self, DecodeError> {
        Ok(Point { x: term.decode_field::<Self, _>(0, 0, "x")?, y: term.decode_field::<Self, _>(0, 1, "y")? })
    }
}

impl Encoder for Point {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        env.make_struct(0, &[self.x.encode(env), self.y.encode(env)])
    }
}

impl<'a> Decoder<'a> for Shape {
    fn type_name() -> String {
        "Shape".to_string()
    }

    fn decode(term: Term<'a>) -> Result<Self, DecodeError> {
        match term.get_variant(1) {
            Some(0) => Ok(Shape::Dot),
            Some(1) => Ok(Shape::Circle(term.decode_payload::<Self, _>(1, "Circle", 0)?)),
            _ => Err(DecodeError::expected::<Self>()),
        }
    }
}

impl Encoder for Shape {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            Shape::Dot => env.make_enum(1, 0, &[]),
            Shape::Circle(p) => env.make_enum(1, 1, &[p.encode(env)]),
        }
    }
}

/// `value` encoded in a mock call and decoded back, with the value the VM holds.
fn round_trip<T>(value: T) -> T
where
    T: Encoder + for<'a> Decoder<'a> + Clone + core::fmt::Debug,
{
    let mut back = None;
    short(vec![], |env, _| {
        let term = value.encode(env);
        back = Some(T::decode(term).unwrap());
        term
    })
    .unwrap();
    back.unwrap()
}

#[test]
fn each_type_of_a_signature_decodes_back_to_what_it_encoded() {
    assert_eq!(round_trip(i64::MIN), i64::MIN);
    assert_eq!(round_trip(-2.5f64), -2.5);
    assert!(round_trip(true));
    assert_eq!(round_trip("héllo".to_string()), "héllo");
    assert_eq!(round_trip(vec![0u8, 255]), vec![0u8, 255]);
    let rows = vec![vec![1.0, 2.5], vec![], vec![4.0]];
    assert_eq!(round_trip(rows.clone()), rows);
    let codes = vec![("ab".to_string(), vec![97i64, 98]), (String::new(), vec![]), ("é".to_string(), vec![195, 169])];
    assert_eq!(round_trip(codes.clone()), codes);
    let nested: Vec<Option<Result<Vec<i64>, String>>> = vec![Some(Ok(vec![1, 2])), Some(Err("e".into())), None];
    assert_eq!(round_trip(nested.clone()), nested);
    let shapes = vec![Shape::Dot, Shape::Circle(Point { x: -3, y: 4 })];
    assert_eq!(round_trip(shapes.clone()), shapes);
}

#[test]
fn a_map_keeps_its_order_and_a_later_pair_of_a_key_wins() {
    let pairs = vec![("b".to_string(), 1i64), ("a".to_string(), 2), ("b".to_string(), 3)];
    assert_eq!(round_trip(pairs), vec![("b".to_string(), 3), ("a".to_string(), 2)]);
    let result = short(vec![], |env, _| ().encode(env));
    assert_eq!(result, Ok(V::Void));
}

#[test]
fn a_string_and_bytes_argument_are_borrowed_from_the_call() {
    let args = vec![V::Str(b"kiwi".to_vec()), V::Bytes(vec![1, 2]), V::List(vec![V::Str(b"a".to_vec())])];
    let result = short(args, |env, args| {
        assert_eq!(args.decode::<&str>(0), Ok("kiwi"));
        assert_eq!(args.decode::<&[u8]>(1), Ok(&[1u8, 2][..]));
        assert_eq!(args.decode::<Vec<&str>>(2), Ok(vec!["a"]));
        env.void()
    });
    assert_eq!(result, Ok(V::Void));
}

/// The text of the error of reading `v`, the first argument of a call, as a `T`.
fn misread<T: for<'a> Decoder<'a> + core::fmt::Debug>(v: V) -> String {
    let mut text = String::new();
    short(vec![v], |env, args| {
        text = args.decode::<T>(0).unwrap_err().to_string();
        env.void()
    })
    .unwrap();
    text
}

#[test]
fn a_bad_part_fails_with_its_path_from_the_argument() {
    let bad_point = || V::Struct(0, vec![V::Str(b"a".to_vec()), V::Int(1)]);
    let text = |s: &str| V::Str(s.as_bytes().to_vec());
    assert_eq!(misread::<Vec<i64>>(V::List(vec![V::Int(1), text("a")])), "argument 1: List[Int].1: expected Int");
    assert_eq!(
        misread::<Vec<(String, Point)>>(V::Map(vec![(text("p"), bad_point())])),
        "argument 1: Map[String, Point].0.value.x: expected Int"
    );
    assert_eq!(
        misread::<Vec<(i64, i64)>>(V::Map(vec![(text("k"), V::Int(1))])),
        "argument 1: Map[Int, Int].0.key: expected Int"
    );
    assert_eq!(misread::<Shape>(V::Enum(1, 1, vec![bad_point()])), "argument 1: Shape.Circle.0.x: expected Int");
    let deep = V::Some(Box::new(V::Ok(Box::new(V::List(vec![V::Int(1), V::Int(2), V::Bool(true)])))));
    assert_eq!(
        misread::<Option<Result<Vec<i64>, String>>>(deep),
        "argument 1: Optional[Result[List[Int]]].some.ok.2: expected Int"
    );
    assert_eq!(misread::<Point>(V::Int(3)), "argument 1: Point: expected Point");
    assert_eq!(misread::<Vec<Vec<f64>>>(V::Int(3)), "argument 1: List[List[Float]]: expected List[List[Float]]");

    let missing = short(vec![], |env, args| {
        assert_eq!(args.decode::<i64>(2).unwrap_err().to_string(), "argument 3: Int: expected Int");
        env.void()
    });
    assert_eq!(missing, Ok(V::Void));
}

#[test]
fn edge_values_and_every_kind_of_map_key_come_back() {
    assert_eq!(round_trip(i64::MAX), i64::MAX);
    assert!(round_trip(f64::NAN).is_nan());
    assert_eq!(round_trip(-0.0f64).to_bits(), (-0.0f64).to_bits());
    assert_eq!(round_trip(vec![(i64::MIN, 1i64), (0, 2)]), vec![(i64::MIN, 1), (0, 2)]);
    let by_bytes = vec![(vec![0u8, 255], "a".to_string()), (vec![], "b".to_string())];
    assert_eq!(round_trip(by_bytes.clone()), by_bytes);
}

#[test]
fn a_term_decodes_and_encodes_as_itself_in_its_own_call() {
    let result = short(vec![V::List(vec![V::Int(1), V::Str(b"x".to_vec())])], |env, args| {
        let items: Vec<Term> = args.decode(0).unwrap();
        assert_eq!(items[0].get_int(), Some(1));
        // A part kept as a term goes back out unchanged.
        vec![items[1]].encode(env)
    });
    assert_eq!(result, Ok(V::List(vec![V::Str(b"x".to_vec())])));
}

#[test]
fn a_term_of_another_call_is_refused() {
    let inner = MockEnv::new(false);
    let _ = short(vec![], |outer, _| {
        let one = outer.string("one");
        let argv: [sys::an_term; 0] = [];
        // SAFETY: the mock env lives for the call, with no arguments.
        unsafe { call(inner.raw(), 0, argv.as_ptr(), Mode::Short, crate::mock::TYPES, |env, _| Ok(one.encode(env))) };
        outer.void()
    });
    // The assert of Term::encode panics, which the inner call catches and makes its failure.
    assert_eq!(inner.failure.borrow().as_deref(), Some("panic: a term of another call"));
}

#[test]
fn a_term_of_a_nested_call_on_the_same_env_is_refused() {
    let mock = MockEnv::new(false);
    let argv: [sys::an_term; 0] = [];
    // SAFETY: the mock env lives for both calls, with no arguments.
    unsafe {
        call(mock.raw(), 0, argv.as_ptr(), Mode::Short, crate::mock::TYPES, |outer, _| {
            call(mock.raw(), 0, argv.as_ptr(), Mode::Short, crate::mock::TYPES, |inner, _| {
                // The inner frame's root list goes away when it returns, so the outer call must not take its term.
                let one = inner.string("one");
                let _ = one.encode(outer);
                Ok(inner.void())
            });
            Ok(outer.void())
        })
    };
    assert_eq!(mock.failure.borrow().as_deref(), Some("panic: a term of another call"));
}

#[test]
fn a_dirty_call_reads_its_arguments_but_not_what_it_staged() {
    let result = dirty(vec![V::List(vec![V::Int(1), V::Int(2)])], |env, args| {
        assert_eq!(args.decode::<Vec<i64>>(0), Ok(vec![1, 2]));
        let staged = vec![1i64, 2].encode(env);
        assert_eq!(staged.decode::<Vec<i64>>().unwrap_err().to_string(), "List[Int]: expected List[Int]");
        assert_eq!("text".encode(env).decode::<String>().unwrap_err().to_string(), "String: expected String");
        staged
    });
    assert_eq!(result, Ok(V::List(vec![V::Int(1), V::Int(2)])));
}
