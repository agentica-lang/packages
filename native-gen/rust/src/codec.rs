//! `Decoder` and `Encoder`: Rust values from terms and back, for the types of a signature.
//!
//! | Agentica | Rust |
//! |---|---|
//! | `Int` | `i64` (never narrower) |
//! | `Float` | `f64` |
//! | `Bool` | `bool` |
//! | `String` | `&'a str` (borrowed for the call) or `String` |
//! | `Bytes` | `&'a [u8]` (borrowed for the call) or `Vec<u8>` |
//! | `List[T]` | `Vec<T>` |
//! | `Map[K, V]` | `Vec<(K, V)>`, in the Map's insertion order both ways |
//! | `Optional[T]` | `Option<T>` |
//! | `Result[T]` | `Result<T, String>` (an encoded error is any `Display`) |
//! | `Void` | `()` (encode only) |
//! | any | `Term<'a>`, the term as it is |
//!
//! A Map is a `Vec` of pairs, not a `HashMap`: the language keeps a Map in insertion order, and a `HashMap` would
//! lose it. Its key is a `MapKey` (`i64`, `String`, `&str`, `Vec<u8>`, `&[u8]`), so a key of another type does not
//! compile. Structs and enums of the block get their codecs from native-gen, through `Term::decode_field`,
//! `Term::decode_payload`, `Env::make_struct` and `Env::make_enum`. A payload that leads back to its own enum stays a
//! `Term<'a>`, as in the C header: the module reads it when it needs it, so a deep value never recurses through the
//! stack of a scheduler.

use core::fmt;

use crate::term::{Args, Env, Term};

/// A value that could not be read: the path to its bad part, from the outermost value in, and the type it should
/// have had. The text has the format of the C header of native-gen (`List[Int].2: expected Int`,
/// `Shape.Circle.0.x: expected Int`, and `argument 1: ...` for an argument of the call), but its path always starts
/// at the value that was decoded (the argument, for `Args::decode`) and is never cut, where C's starts at the cursor
/// that failed and stops at 192 bytes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DecodeError {
    argument: Option<usize>,
    root: String,
    // The segments innermost first: each container adds its own as the error goes up.
    path: Vec<String>,
    expected: String,
}

impl DecodeError {
    /// A term that is not a `T`.
    pub fn expected<'a, T: Decoder<'a>>() -> Self {
        DecodeError { argument: None, root: T::type_name(), path: Vec::new(), expected: T::type_name() }
    }

    /// The error of a part of a `T`, at `segment` (an index, a field name, `some`, `ok`).
    pub fn inside<'a, T: Decoder<'a>>(mut self, segment: impl fmt::Display) -> Self {
        self.path.push(segment.to_string());
        self.root = T::type_name();
        self
    }

    /// Two segments at once, for a pair of a Map (`2.value`) or a payload of a variant (`Circle.0`).
    pub fn inside2<'a, T: Decoder<'a>>(mut self, first: impl fmt::Display, second: impl fmt::Display) -> Self {
        self.path.push(second.to_string());
        self.inside::<T>(first)
    }

    /// The error as the one of the argument `index` (from 0) of the call.
    pub fn at_argument(mut self, index: usize) -> Self {
        self.argument = Some(index);
        self
    }
}

impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if let Some(index) = self.argument {
            write!(f, "argument {}: ", index + 1)?;
        }
        f.write_str(&self.root)?;
        for segment in self.path.iter().rev() {
            write!(f, ".{segment}")?;
        }
        write!(f, ": expected {}", self.expected)
    }
}

impl std::error::Error for DecodeError {}

/// A Rust value read from a term of the call `'a`.
pub trait Decoder<'a>: Sized {
    /// The canonical Agentica type of the value (`List[Int]`), for the path of a failed read.
    fn type_name() -> String;

    fn decode(term: Term<'a>) -> Result<Self, DecodeError>;
}

/// A Rust value made into a term of the call `'a`.
pub trait Encoder {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a>;
}

impl<'a> Args<'a> {
    /// The argument `index` (from 0) as a `T`; an error `argument N: PATH: expected TYPE` when it is not one or is
    /// missing.
    pub fn decode<T: Decoder<'a>>(&self, index: usize) -> Result<T, DecodeError> {
        let term = self.get(index).ok_or_else(|| DecodeError::expected::<T>().at_argument(index))?;
        T::decode(term).map_err(|e| e.at_argument(index))
    }
}

/// The reads of a term and of the parts of a struct or enum, for the codecs that native-gen writes.
impl<'a> Term<'a> {
    /// The term as a `T`.
    pub fn decode<T: Decoder<'a>>(self) -> Result<T, DecodeError> {
        T::decode(self)
    }

    /// The field `field`, named `name`, of a struct `S` of row `type_`.
    pub fn decode_field<S: Decoder<'a>, T: Decoder<'a>>(
        self,
        type_: u32,
        field: u32,
        name: &str,
    ) -> Result<T, DecodeError> {
        let part = self.get_field(type_, field).ok_or_else(DecodeError::expected::<S>)?;
        T::decode(part).map_err(|e| e.inside::<S>(name))
    }

    /// The payload `k` of the variant named `variant` of an enum `S` of row `type_`. Call it only once `get_variant`
    /// gave that variant: the VM reads the payload of the variant the term has, whatever `variant` names.
    pub fn decode_payload<S: Decoder<'a>, T: Decoder<'a>>(
        self,
        type_: u32,
        variant: &str,
        k: u32,
    ) -> Result<T, DecodeError> {
        let part = self.get_payload(type_, k).ok_or_else(DecodeError::expected::<S>)?;
        T::decode(part).map_err(|e| e.inside2::<S>(variant, k))
    }
}

impl<T: Encoder + ?Sized> Encoder for &T {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        (**self).encode(env)
    }
}

/// The term itself, for a part that the module reads when it needs it (a payload that leads back to its own enum).
impl<'a> Decoder<'a> for Term<'a> {
    fn type_name() -> String {
        "a value".to_string()
    }

    fn decode(term: Term<'a>) -> Result<Self, DecodeError> {
        Ok(term)
    }
}

impl Encoder for Term<'_> {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        // Only a term of this call can be encoded in it: `Env<'a>` and `Term<'a>` share the call's lifetime, which
        // a codec cannot name for `self`, so the two are checked to be one env.
        // The same env and root list is the same live frame of `call` (see Env::same_call): a term of a nested `call` on
        // the same env would lose its root when that frame returns, so it is refused.
        assert!(self.env().same_call(env), "a term of another call");
        // SAFETY: the term belongs to this env (checked above), so it is valid for the call `'a`.
        unsafe { self.rebind(env) }
    }
}

/// The types a Map key can have: Int, String and Bytes, as in the language. A key of another type does not compile:
///
/// ```compile_fail,E0599
/// # use agentica_native::*;
/// fn keyed(env: Env<'_>) -> Term<'_> {
///     vec![(1.5f64, 1i64)].encode(env)
/// }
/// ```
///
/// ```no_run
/// # use agentica_native::*;
/// fn keyed(env: Env<'_>) -> Term<'_> {
///     vec![(1i64, 1i64)].encode(env)
/// }
/// ```
pub trait MapKey {}

impl MapKey for i64 {}
impl MapKey for String {}
impl MapKey for &str {}
impl MapKey for Vec<u8> {}
impl MapKey for &[u8] {}

impl Encoder for () {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        env.void()
    }
}

macro_rules! scalar {
    ($rust:ty, $name:literal, $get:ident, $make:ident) => {
        impl<'a> Decoder<'a> for $rust {
            fn type_name() -> String {
                $name.to_string()
            }

            fn decode(term: Term<'a>) -> Result<Self, DecodeError> {
                term.$get().ok_or_else(DecodeError::expected::<Self>)
            }
        }

        impl Encoder for $rust {
            fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
                env.$make(*self)
            }
        }
    };
}

scalar!(i64, "Int", get_int, int);
scalar!(f64, "Float", get_float, float);
scalar!(bool, "Bool", get_bool, bool);

impl<'a> Decoder<'a> for &'a str {
    fn type_name() -> String {
        "String".to_string()
    }

    fn decode(term: Term<'a>) -> Result<Self, DecodeError> {
        term.get_str().ok_or_else(DecodeError::expected::<Self>)
    }
}

impl<'a> Decoder<'a> for String {
    fn type_name() -> String {
        "String".to_string()
    }

    fn decode(term: Term<'a>) -> Result<Self, DecodeError> {
        term.get_str().map(str::to_string).ok_or_else(DecodeError::expected::<Self>)
    }
}

impl Encoder for str {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        env.string(self)
    }
}

impl Encoder for String {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        env.string(self)
    }
}

impl<'a> Decoder<'a> for &'a [u8] {
    fn type_name() -> String {
        "Bytes".to_string()
    }

    fn decode(term: Term<'a>) -> Result<Self, DecodeError> {
        term.get_bytes().ok_or_else(DecodeError::expected::<Self>)
    }
}

// `u8` is neither a Decoder nor an Encoder, so these never overlap the impls of `Vec<T>` below: `Vec<u8>` is Bytes.
impl<'a> Decoder<'a> for Vec<u8> {
    fn type_name() -> String {
        "Bytes".to_string()
    }

    fn decode(term: Term<'a>) -> Result<Self, DecodeError> {
        term.get_bytes().map(<[u8]>::to_vec).ok_or_else(DecodeError::expected::<Self>)
    }
}

impl Encoder for [u8] {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        env.bytes(self)
    }
}

impl Encoder for Vec<u8> {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        env.bytes(self)
    }
}

impl<'a, T: Decoder<'a>> Decoder<'a> for Vec<T> {
    fn type_name() -> String {
        format!("List[{}]", T::type_name())
    }

    fn decode(term: Term<'a>) -> Result<Self, DecodeError> {
        let read = term.list_items(|items| {
            let mut out = Vec::with_capacity(items.len());
            for (at, item) in items.enumerate() {
                out.push(T::decode(item).map_err(|e| e.inside::<Self>(at))?);
            }
            Ok(out)
        });
        read.unwrap_or_else(|| Err(DecodeError::expected::<Self>()))
    }
}

impl<T: Encoder> Encoder for Vec<T> {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        env.list(self.iter().map(|item| item.encode(env)))
    }
}

// A tuple is never a Decoder or an Encoder, so a Vec of pairs is a Map, never a List.
impl<'a, K: Decoder<'a> + MapKey, V: Decoder<'a>> Decoder<'a> for Vec<(K, V)> {
    fn type_name() -> String {
        format!("Map[{}, {}]", K::type_name(), V::type_name())
    }

    fn decode(term: Term<'a>) -> Result<Self, DecodeError> {
        let read = term.map_pairs(|pairs| {
            let mut out = Vec::with_capacity(pairs.len());
            for (at, (key, value)) in pairs.enumerate() {
                let key = K::decode(key).map_err(|e| e.inside2::<Self>(at, "key"))?;
                let value = V::decode(value).map_err(|e| e.inside2::<Self>(at, "value"))?;
                out.push((key, value));
            }
            Ok(out)
        });
        read.unwrap_or_else(|| Err(DecodeError::expected::<Self>()))
    }
}

/// A Map in the order of the pairs; a later pair of one key replaces the earlier one.
impl<K: Encoder + MapKey, V: Encoder> Encoder for Vec<(K, V)> {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        env.map(self.iter().map(|(key, value)| (key.encode(env), value.encode(env))))
    }
}

impl<'a, T: Decoder<'a>> Decoder<'a> for Option<T> {
    fn type_name() -> String {
        format!("Optional[{}]", T::type_name())
    }

    fn decode(term: Term<'a>) -> Result<Self, DecodeError> {
        match term.get_optional().ok_or_else(DecodeError::expected::<Self>)? {
            Some(value) => T::decode(value).map(Some).map_err(|e| e.inside::<Self>("some")),
            None => Ok(None),
        }
    }
}

impl<T: Encoder> Encoder for Option<T> {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            Some(value) => env.some(value.encode(env)),
            None => env.none(),
        }
    }
}

/// An Agentica Result: its error is a message.
impl<'a, T: Decoder<'a>> Decoder<'a> for Result<T, String> {
    fn type_name() -> String {
        format!("Result[{}]", T::type_name())
    }

    fn decode(term: Term<'a>) -> Result<Self, DecodeError> {
        match term.get_result().ok_or_else(DecodeError::expected::<Self>)? {
            Ok(value) => T::decode(value).map(Ok).map_err(|e| e.inside::<Self>("ok")),
            Err(message) => String::decode(message).map(Err).map_err(|e| e.inside::<Self>("error")),
        }
    }
}

/// An Agentica Result, the error made a message with `Display`.
impl<T: Encoder, E: fmt::Display> Encoder for Result<T, E> {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            Ok(value) => env.ok(value.encode(env)),
            Err(error) => env.error(&error.to_string()),
        }
    }
}
