---
title: native-gen
description: The C header of an extern module block. Write plain C functions with C types; the wrappers, the argument checks and the tables of the module are generated from the .agc.
---

`native-gen` reads the `extern module` block of an `.agc` file and writes a C header for it. The C author writes plain functions with C types; the header has their prototypes, and the wrappers that check the arguments and the function and type tables of the module. The `.agc` is the one source: every signature and shape comes from `std/analysis`, the same text that the VM compares with the tables when it loads the module.

## Install

Needs Agentica 0.27.0 or later. Add it with the prefixed tag of the release, in a project with an `agentica.toml`:

```sh
agentica add native-gen https://github.com/agentica-lang/packages --tag native-gen-0.1.0 --subdir native-gen
```

That writes this line of `agentica.toml`, and the entry of `agentica.lock`:

```toml
[dependencies]
native-gen = { git = "https://github.com/agentica-lang/packages", tag = "native-gen-0.1.0", subdir = "native-gen" }
```

The releases and their notes are in the [changelog](https://github.com/agentica-lang/packages/blob/main/native-gen/CHANGELOG.md).

## Example

A block of `stats.agc`:

```agentica
struct Summary
  count: Int
  min: Float
  max: Float
  mean: Float
end

enum Cell
  Empty
  Number(Float)
  Text(String)
end

extern module "stats"
  ## The count, smallest, largest and mean of the values; none for no values.
  def summary(values: List[Float]) -> Optional[Summary]
  def rows(text: String) -> Result[List[Map[String, Cell]]]
end
```

Make the header, and make it again after each change to the block:

```sh
agentica deps/native-gen/cli.agc stats.agc --output native/stats_native.h
```

The C file defines `STATS_NATIVE_IMPLEMENTATION` before it includes the header, writes one function per prototype, and ends with `STATS_NATIVE_MODULE(NULL)`:

```c
#define STATS_NATIVE_IMPLEMENTATION
#include "stats_native.h"

an_term stats_summary(an_env *env, stats_list_Float values) {
  double x;
  int more;
  if (values.len == 0) return an_none(env);
  while ((more = stats_list_Float_next(env, &values, &x)) == 1) {
    /* ... */
  }
  if (more < 0) return an_void(env); /* a bad item: the call has failed */
  stats_Summary summary = {count, min, max, total / count};
  return stats_optional_Summary_some(env, summary);
}

an_term stats_rows(an_env *env, ng_str text) {
  /* text.data, text.len; a cell is stats_Cell_Empty(env), stats_Cell_Number(env, x) or stats_Cell_Text(env, s);
     the rows end with stats_result_list_map_String_Cell_ok(env, stats_list_map_String_Cell_end(env, &b)), b being
     the builder of the rows, or with an_error(env, message, len) */
}

STATS_NATIVE_MODULE(NULL)
```

A function you did not write is a link error, not a failure when the module loads. Other `.c` files of the module include the header without the define and get the prototypes and constants only; the implementation part has its own guard, so the one file may include the header before the define too.

## The header

- The prefix of the C names is the library name of the block up to its first `.` (`stats`), or `--prefix NAME`. Functions use it in lower case, macros and constants in capitals. `an`, `ng`, `agentica` and a prefix that starts with `an_` or `ng_` belong to the C API or to native-gen and are refused.
- One prototype per function, `an_term PREFIX_name(an_env *env, ...)`, with the `##` doc above it. `Int` is `int64_t`, `Float` `double`, `Bool` `bool`, `String` `ng_str` and `Bytes` `ng_buf` (`data` and `len`, borrowed for the call: copy them to keep them). A struct or enum of the program is its C value, a `List` or `Map` a cursor and an `Optional` or `Result` a struct (below). A resource is its state, `struct PREFIX_Name_state *` (below). The result is always an `an_term`.
- Each wrapper checks the arguments in order and fails the call at the first one that does not decode: a scalar or a resource with `an_badarg(env, i)`, a struct, enum, `Optional` or `Result` with the path of its bad part (`argument 1: Shape.Circle.0.x: expected Int`). A `List` or `Map` argument is only opened (one that is not fails as `argument 1: List[Float]: expected List[Float]`): its items are read by `_next`.
- `def` is `AN_SHORT` and `compute def` is `AN_DIRTY`.
- `PREFIX_TYPE_Name` is the row of a struct or enum, the `TYPE` of `an_struct` and `an_enum`; `PREFIX_Name_member` is a field or variant, in declared order. `PREFIX_RESOURCE_Name` is the row of a resource.
- A struct is `typedef struct {...} PREFIX_Name`, a field by its name (a C keyword gets a trailing `_`). An enum is a `tag` of type `PREFIX_Name_tag` (its values are `PREFIX_Name_Variant`, so a `switch` on it is checked by `-Wswitch`) and a union `as` with one struct per variant that has a payload, `_0`, `_1`, ... in order: `shape.as.Circle._1`. A field or payload of another struct or enum of the block is embedded by value, unless that type leads back to its owner (a recursive enum), where it is an `an_term`. A variant with a payload cannot be named after a C macro (`NULL`, `EOF`, ...).
- For a type that a parameter reaches, `bool PREFIX_Name_get(env, term, &out)` reads a term into its C value. On false the call has already failed, with the path of the bad part; a function whose signature does not reach the type reads none (`Point: expected Point`). For a type that a result reaches, `PREFIX_Name_make(env, &value)` makes the term, and an enum has one constructor per variant, `PREFIX_Shape_Circle(env, center, radius)`. A String or Bytes in a C value is borrowed and a term lasts for the call: keep C values in locals.
- A `List` or `Map` that a parameter reaches is a cursor, `PREFIX_list_Float` or `PREFIX_map_String_Point` (`Map[String, List[Int]]` is `PREFIX_map_String_list_Int`), with `len`. `PREFIX_list_Float_next(env, &values, &x)` reads the next item (`_next(env, &map, &key, &value)` for a Map) and gives 1 for an item, 0 at the end, and -1 when the item does not decode: the call has then failed with the path of the item (`argument 1: List[Int].1: expected Int`, `argument 1: Map[String, Point].0.value.x: expected Int`), and every later `_next` gives -1 too. Nothing is copied to an array. An item that is a `List` or `Map` is its own cursor, and its failures name the path from it (`argument 1: List[Float].1`); one that is an `Optional` or `Result` is its struct (`_next` fills a `PREFIX_optional_String`). The `argument N:` comes from the argument the wrapper opened: the cursor of an argument, and every cursor under it (an item, or the `value` of an `Optional` or `Result`), keep that N in their field `argument`. `PREFIX_list_Float_open(env, term, &cursor)` opens one held as a term, such as a field of a struct; its failures have no `argument N:` (`List[Int].1: expected Int`). Open cursors with `_open` only, never by hand.
- A `List` or `Map` that a result reaches has a builder: `PREFIX_list_Float_builder b`, `_begin(env, &b, hint)` (`hint` the expected item count, 0 when unknown), `_push(env, &b, x)` and `_end(env, &b)`, which gives the term; a Map has `_begin(env, &b)`, `_put(env, &b, key, value)` and `_end`. An item is the C value of its type, and a `List`, `Map`, `Optional` or `Result` item is the term its own builder or constructor made.
- An `Optional` that a parameter reaches is `PREFIX_optional_Point` (`some`, `value`) and a `Result` is `PREFIX_result_Int` (`ok`, `value`, and `error`, its message as an `ng_str` borrowed for the call). `value` is zero when there is none. `PREFIX_optional_Point_get(env, term, &out)` reads one held as a term. One that a result reaches has a constructor, `PREFIX_optional_Point_some(env, point)` or `PREFIX_result_Int_ok(env, n)`; `an_none(env)` and `an_error(env, message, len)` make the others.
- Cursors, builders and the structs of `Optional` and `Result` hold terms: keep them in C locals, for the call only.
- A resource needs `struct PREFIX_Name_state` and `PREFIX_Name_FREE` (a `void (*)(void *state)`, or `NULL`), both defined before `PREFIX_NATIVE_MODULE`. C11 has no empty struct: a resource with no state still needs one member. `struct PREFIX_Name_state *PREFIX_Name_new(env, &out)` makes one, sets `out` to its term (to return, or to push in a builder) and gives its zeroed state; in a function whose signature does not reach the resource it gives NULL, sets `out` to Void and fails the call. The VM calls `PREFIX_Name_FREE` once, when the resource is closed, its task ends or the run ends; it gets only the state and may run on another VM thread while other calls run, so what it shares with them must be thread-safe. The state holds C data only, never a term. `PREFIX_Name_get(env, term)` gives the state of a resource that is an argument of the call, and NULL for any other term, one made by `_new` in the same call included. A state pointer is valid until the call returns: do not keep it. A wrong or closed resource never reaches the wrapper: the checker (`CHECK-NATIVE-TYPE`) and the VM (`RUNTIME-NATIVE-CLOSED`) stop it first, so its `an_badarg` is a guard only.
- Names: `empty?` is `PREFIX_empty_p` and `save!` is `PREFIX_save_bang`. A parameter that is a C or C++ keyword, `env`, a type or macro a prototype may use (`int64_t`, `size_t`, `uint8_t`, `uint32_t`, `errno`), or that starts with `an_` or `ng_`, gets a trailing `_` (`int_`). The header compiles as C11 and as C++.
- The header starts with a check of the version of `agentica_native.h`: it stops the build when the API is older than the block needs.

## A new module

`new` starts a module in a package (the command is `cli.agc new`, `native-gen new` in its errors):

```sh
agentica deps/native-gen/cli.agc new demo
agentica deps/native-gen/cli.agc new path/to/pkg/demo
```

It writes, in the folder of the path (the current one for a bare name):

- `demo.agc`, with an `extern module "demo"` block of one example function, `add(a: Int, b: Int) -> Int`, and a `main` that calls it;
- `native/demo.c`, with one body per function that fails the call with `not written yet` until you write it, and `DEMO_NATIVE_MODULE(NULL)` at its end;
- `native/demo_native.h`, the header made from the new `.agc`;
- the `[native.demo]` entry of `agentica.toml` (`build = { sources = ["native/demo.c"] }`), added at the end of the file, or a new `agentica.toml` with `name = "demo"`. A comment above the entry gives the two commands that make and check the header, run from that folder.

The package builds and loads as it is: running `demo.agc` fails at the call with `add: not written yet`. Replace the example with your functions, then make the header again.

The name is the `[native.NAME]` of `agentica.toml`, the library of the block and the start of the C names: a lowercase letter, then lowercase letters, digits and `_`, at most 64 characters, not a device name of Windows (`con`, `nul`, `com1`, ...), and not a prefix of the C API (`an`, `ng`, `agentica`, or one that starts with `an_` or `ng_`). Pass `NAME` or `FOLDER/NAME`, without `.agc`.

With `--lang rust`, `new` starts a [Rust module](#a-rust-module) instead:

```sh
agentica deps/native-gen/cli.agc new --lang rust demo
agentica deps/native-gen/cli.agc build demo.agc
```

It writes `demo.agc` (the same block and `main`) and the crate `rust/`, laid out as the example below: `Cargo.toml`, `.gitignore` (`target/` and `Cargo.lock`), `src/lib.rs` with one method per function that returns `Err(Raise::new("not written yet"))`, and `src/demo_native.rs`, the Rust file made from the new `.agc`. It makes an `agentica.toml` with `name = "demo"` when the folder has none, and adds no `[native.demo]` entry: `build` adds the one of the system, with the library it built. The name also cannot be a Rust keyword or the name of a Rust crate (`fn`, `test`, `std`, ...). After `build`, running `demo.agc` fails at the call with `add: not written yet`, as for C.

`new` writes only new files. It writes nothing when `demo.agc`, `native/demo.c` or the header (for Rust, a file of `rust/` that it writes) is there, or when `agentica.toml` has `native.demo` already (`NATIVE-GEN-EXISTS`), or when `agentica.toml` with the entry added is not TOML (`NATIVE-GEN-MANIFEST`). Every text is made before the first write; only a write that fails midway (`NATIVE-GEN-IO`) leaves the files written before it.

## A Rust module

A module can be written in Rust instead, on the `agentica-native` crate that native-gen carries in `deps/native-gen/native/agentica-native`. The crate of the module is the folder `rust/` at the package root (the nearest folder up from the `.agc` with an `agentica.toml`), and depends on that crate by path. The package [examples/rust_math](https://github.com/agentica-lang/packages/tree/main/native-gen/examples/rust_math) is a whole one; CI builds it and runs it, and checks that the files below are its files.

It needs cargo, and the install above, which puts the crate in `deps/native-gen/`.

`agentica.toml`, before the build:

```toml
# A native module in Rust (the native-gen docs show it). `agentica deps/native-gen/cli.agc build math.agc` builds it
# and adds the [native.math] entry of the system below; rust/build-check.sh does that on a copy in CI.
name = "native-gen-rust-math"
```

`math.agc`:

```agentica {mode="check"}
## A native module written in Rust: `rust/src/lib.rs` implements the block on the file that native-gen makes from it,
## and `cli.agc build math.agc` builds it into native/ and adds its entry to agentica.toml.

struct Point
  x: Float
  y: Float
end

extern module "math"
  ## The sum of a and b.
  def add(a: Int, b: Int) -> Int
  ## The mean of the values; none for no values.
  def mean(values: List[Float]) -> Optional[Float]
  ## x kept between low and high.
  def clamp(x: Float, low: Float, high: Float) -> Float
  ## The point halfway between a and b.
  def midpoint(a: Point, b: Point) -> Point
end

def main() -> Void
  puts(add(2, 3))
  puts(mean([1.0, 2.0, 6.0]))
  puts(mean([]))
  puts(clamp(12.5, 0.0, 10.0))
  puts(midpoint(Point(x: 0.0, y: 0.0), Point(x: 4.0, y: 2.0)))
end
```

`rust/Cargo.toml`:

```toml
[package]
name = "math"
version = "0.1.0"
edition = "2024"
rust-version = "1.90"
publish = false

[lib]
crate-type = ["cdylib"]

[dependencies]
agentica-native = { path = "../deps/native-gen/native/agentica-native" }
```

`rust/src/lib.rs`:

```rust
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
```

`rust/src/math_native.rs` is the file that `build` writes from the block: the struct `Point`, the trait `MathNative` with one method per function, and `module`. Build the module, then run the program, from the package root:

```sh
agentica deps/native-gen/cli.agc build math.agc
agentica math.agc
```

The output of `build` on Linux (cargo prints its progress on stderr):

```text
wrote rust/src/math_native.rs
copied rust/target/release/libmath.so to native/libmath.so
added native.math.linux to agentica.toml
```

With a cargo workspace or `CARGO_TARGET_DIR`, the library that cargo built is at another path, which the `copied` line names.

The entry that `build` adds to `agentica.toml`:

```toml
[native.math]
linux = { file = "native/libmath.so" }
```

The output of `agentica math.agc`:

```text
5
some(3.0)
none
10.0
Point(x: 2.0, y: 1.0)
```

A native module cannot call back into Agentica: its functions get values and return values, and never run an Agentica function or block. Return the data, or a resource, and loop in Agentica. A plain `extern` block can pass a function of the program to C as a function pointer, with a [`callback`](https://agentica-lang.github.io/agentica/library/io-and-system/native/types/#callbacks) line.

What `build` does, with paths from the package root:

- It writes `rust/src/NAME_native.rs` (NAME is the library of the block, `math`) when it changed: the types of the block with their codecs, the trait `MathNative` that `src/lib.rs` implements, and `module::<Impl>()` for `agentica_native::export!`. Declare it in `src/lib.rs` with `#[rustfmt::skip] mod math_native;`.
- It runs `cargo build --release` on the crate (from the current folder, so a `.cargo/config.toml` is found from there, not from `rust/`), and copies the library to `native/libmath.so` on Linux, `native/libmath.dylib` on macOS or `native/math.dll` on Windows.
- It adds the entry of the system to `agentica.toml`, `linux = { file = "native/libmath.so" }` under `[native.math]` (or a new `[native.math]` at the end). An entry that is there already is kept, and the library goes to its `file`, which must be in `native/`. `agentica.toml` is read again after cargo, so an edit made meanwhile is kept.
- It prints one line per step: what it wrote, or that the file is current. A second run with nothing changed writes nothing.

A package that others install does not build its Rust module: commit the library in `native/` for each system, and the entry of each, as you build them on that system. `build` does not cross-build: the library cargo makes is copied as the entry of the system it runs on. Commit `rust/src/NAME_native.rs` too, and check in CI that it is current; `build --check` runs no cargo:

```sh
agentica deps/native-gen/cli.agc build math.agc --check
```

`--check` covers only the generated Rust file, not the library or the manifest entry.

`build` needs `cargo` on `PATH` and an `agentica.toml` at the package root, and the library of the block must be a module name (the rule of `new`). The block is read without the `[native.NAME]` entries of the manifest, so a library that is not built yet does not stop it.

## Errors

An error is one line on stderr, `native-gen: [CODE] message`, and the exit code is 1. Bad usage prints the usage error and a `Try 'native-gen --help'` line (`Try 'native-gen new --help'` for `new`, which also takes a missing or an extra argument as bad usage), and the exit code is 2.

| Code | When |
|---|---|
| `NATIVE-GEN-NAME` | two names map to one C identifier (`empty?` and `empty_p`), or a variant with a payload is named after a C macro |
| `NATIVE-GEN-BLOCK` | the file has no `extern module` block, or more than one; for `build`, its library is not a module name |
| `NATIVE-GEN-PREFIX` | the prefix is not a C identifier, or is the C API's; give another with `--prefix`. For `new`, the name breaks the rule above, or is the C API's (`an`, `ng`, `agentica`, or starts with `an_` or `ng_`) |
| `NATIVE-GEN-UNKNOWN` | `std/analysis` gives a function mode or a type kind that this version does not know |
| `NATIVE-GEN-STALE` | `--check`: the file at `--output` is not the header that the `.agc` gives; `build --check`: `rust/src/NAME_native.rs` is not the one it gives |
| `NATIVE-GEN-EXISTS` | `new`: a file it would write is there, or `agentica.toml` has `native.NAME` already |
| `NATIVE-GEN-MANIFEST` | `new`: `agentica.toml`, with the entry added, is not TOML. `build`: `[native.NAME]` has a `build` table, its entry for the system has no `file` or one outside `native/`, or the entry cannot be added (no `[native.NAME]` line to add it under, a `native` table written inline) |
| `NATIVE-GEN-OS` | `build`: a system other than linux, macos and windows |
| `NATIVE-GEN-CARGO` | `build`: `cargo` is not on `PATH`, fails, or builds no single cdylib |
| `NATIVE-GEN-IO` | a file cannot be read or written; for `build`, also no `rust/Cargo.toml`, or no `agentica.toml` up from the file |
| any other | the code of the diagnostic when the `.agc` does not check |

## Check in CI

Commit the header, and fail the build when it is stale:

```sh
agentica deps/native-gen/cli.agc stats.agc --output native/stats_native.h --check
```

From a program, `NativeGen.header(path, prefix = "")` from `import NativeGen from "pkg/native-gen/native_gen"` returns the text of the header.
