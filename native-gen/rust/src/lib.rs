//! Native modules of Agentica in safe Rust, over `agentica_native.h`.
//!
//! The `.agc` is the one source of a module: native-gen writes the Rust side of its `extern module` block, and this
//! crate is what that code stands on. `Env` is one call of the VM and `Term` a value of it, both bound to the call by
//! a lifetime, so nothing the VM lends outlives the call.

pub mod sys;
mod term;

#[cfg(test)]
mod mock;
#[cfg(test)]
mod tests;

pub use term::{Env, ListItems, MapPairs, Term};
