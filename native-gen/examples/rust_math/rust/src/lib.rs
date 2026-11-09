//! The Rust side of math.agc, on the file `src/math_native.rs` that native-gen makes from its block.

#[rustfmt::skip]
mod math_native;

use agentica_native::{Env, Raise};

use crate::math_native::{MathNative, Point, module};

struct Math;

impl MathNative for Math {
    fn add(_env: Env<'_>, a: i64, b: i64) -> Result<i64, Raise> {
        a.checked_add(b).ok_or_else(|| Raise::new("the sum is out of range"))
    }

    fn mean(_env: Env<'_>, values: Vec<f64>) -> Result<Option<f64>, Raise> {
        if values.is_empty() {
            return Ok(None);
        }
        Ok(Some(values.iter().sum::<f64>() / values.len() as f64))
    }

    fn clamp(_env: Env<'_>, x: f64, low: f64, high: f64) -> Result<f64, Raise> {
        if low.is_nan() || high.is_nan() || low > high {
            return Err(Raise::new("low is above high, or not a number"));
        }
        Ok(x.clamp(low, high))
    }

    fn midpoint(_env: Env<'_>, a: Point, b: Point) -> Result<Point, Raise> {
        Ok(Point { x: (a.x + b.x) / 2.0, y: (a.y + b.y) / 2.0 })
    }
}

agentica_native::export!(module::<Math>());
