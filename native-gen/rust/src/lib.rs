//! Native modules of Agentica in safe Rust, over `agentica_native.h`.
//!
//! The `.agc` is the one source of a module: native-gen writes the Rust side of its `extern module` block, and this
//! crate is what that code stands on. `Env` is one call of the VM and `Term` a value of it, both bound to the call by
//! a lifetime, so nothing the VM lends outlives the call. `Decoder` and `Encoder` turn terms into Rust values of the
//! types of a signature and back. `Module` is the tables that `export!` gives the VM, `call` the boundary of each
//! call (a failure is `Err(Raise)`, a panic is caught), and `ResourceArc` a value the program holds as a resource.

#[cfg(panic = "abort")]
compile_error!("agentica-native catches a panic at the boundary of each call: build with panic = \"unwind\"");

mod codec;
mod module;
mod resource;
pub mod sys;
mod term;

#[cfg(test)]
mod codec_tests;
#[cfg(test)]
mod mock;
#[cfg(test)]
mod module_tests;
#[cfg(test)]
mod tests;

pub use codec::{DecodeError, Decoder, Encoder, MapKey};
pub use module::{Module, init, types};
pub use resource::ResourceArc;
pub use term::{Args, Arity, Env, ListItems, MapPairs, Mode, Raise, Term, call};
