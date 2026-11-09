// The Rust side of `extern module "math"` in math.agc, made by native-gen.
// Do not edit it: change the .agc and make it again.

#[allow(unused_imports)]
use agentica_native::{DecodeError, Decoder, Encoder, Env, Mode, Module, Raise, ResourceArc, Term, sys, types};

#[derive(Clone, Debug, PartialEq)]
#[allow(clippy::type_complexity, clippy::upper_case_acronyms)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

impl<'a> Decoder<'a> for Point {
    fn type_name() -> String {
        "Point".to_string()
    }

    fn decode(term: Term<'a>) -> Result<Self, DecodeError> {
        Ok(Point {
            x: term.decode_field::<Self, _>(0, 0, "x")?,
            y: term.decode_field::<Self, _>(0, 1, "y")?,
        })
    }
}

impl Encoder for Point {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        env.make_struct(0, &[self.x.encode(env), self.y.encode(env)])
    }
}

/// The functions of `extern module "math"`, which the module implements. A method fails
/// its call with `Err(Raise)`; an Agentica `Result` is the value inside `Ok`.
#[allow(clippy::type_complexity, clippy::too_many_arguments, clippy::needless_lifetimes)]
pub trait MathNative {
    /// The sum of a and b.
    fn add(env: Env<'_>, a: i64, b: i64) -> Result<i64, Raise>;
    /// The mean of the values; none for no values.
    fn mean(env: Env<'_>, values: Vec<f64>) -> Result<Option<f64>, Raise>;
    /// x kept between low and high.
    fn clamp(env: Env<'_>, x: f64, low: f64, high: f64) -> Result<f64, Raise>;
    /// The point halfway between a and b.
    fn midpoint(env: Env<'_>, a: Point, b: Point) -> Result<Point, Raise>;
}

unsafe extern "C" fn native_add<I: MathNative>(
    env: *mut sys::an_env,
    argc: core::ffi::c_int,
    argv: *const sys::an_term,
) -> sys::an_term {
    // SAFETY: the VM calls it through the table of `module`, with its own env and arguments, in the
    // row's mode.
    unsafe {
        agentica_native::call(env, argc, argv, Mode::Short, types(), |env, args| {
            Ok(I::add(env, args.decode(0)?, args.decode(1)?)?.encode(env))
        })
    }
}

unsafe extern "C" fn native_mean<I: MathNative>(
    env: *mut sys::an_env,
    argc: core::ffi::c_int,
    argv: *const sys::an_term,
) -> sys::an_term {
    // SAFETY: the VM calls it through the table of `module`, with its own env and arguments, in the
    // row's mode.
    unsafe {
        agentica_native::call(env, argc, argv, Mode::Short, types(), |env, args| {
            Ok(I::mean(env, args.decode(0)?)?.encode(env))
        })
    }
}

unsafe extern "C" fn native_clamp<I: MathNative>(
    env: *mut sys::an_env,
    argc: core::ffi::c_int,
    argv: *const sys::an_term,
) -> sys::an_term {
    // SAFETY: the VM calls it through the table of `module`, with its own env and arguments, in the
    // row's mode.
    unsafe {
        agentica_native::call(env, argc, argv, Mode::Short, types(), |env, args| {
            Ok(I::clamp(env, args.decode(0)?, args.decode(1)?, args.decode(2)?)?.encode(env))
        })
    }
}

unsafe extern "C" fn native_midpoint<I: MathNative>(
    env: *mut sys::an_env,
    argc: core::ffi::c_int,
    argv: *const sys::an_term,
) -> sys::an_term {
    // SAFETY: the VM calls it through the table of `module`, with its own env and arguments, in the
    // row's mode.
    unsafe {
        agentica_native::call(env, argc, argv, Mode::Short, types(), |env, args| {
            Ok(I::midpoint(env, args.decode(0)?, args.decode(1)?)?.encode(env))
        })
    }
}

/// The tables of the module: `agentica_native::export!(module::<Impl>());` with `Impl` the type that implements
/// `MathNative`.
pub fn module<I: MathNative>() -> Module {
    Module::new("math")
        .function("add", "(Int, Int) -> Int", native_add::<I>, Mode::Short)
        .function("mean", "(List[Float]) -> Optional[Float]", native_mean::<I>, Mode::Short)
        .function("clamp", "(Float, Float, Float) -> Float", native_clamp::<I>, Mode::Short)
        .function("midpoint", "(Point, Point) -> Point", native_midpoint::<I>, Mode::Short)
        .struct_type("Point", "x: Float, y: Float")
}
