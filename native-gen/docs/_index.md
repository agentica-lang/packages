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

`new` writes only new files. It writes nothing when `demo.agc`, `native/demo.c` or the header is there, or when `agentica.toml` has `native.demo` already (`NATIVE-GEN-EXISTS`), or when `agentica.toml` with the entry added is not TOML (`NATIVE-GEN-MANIFEST`). Every text is made before the first write; only a write that fails midway (`NATIVE-GEN-IO`) leaves the files written before it.

## A Rust module

A module can be written in Rust instead, on the `agentica-native` crate that native-gen carries in `deps/native-gen/native/agentica-native`. The crate of the module is the folder `rust/` at the package root, the nearest folder up from the `.agc` with an `agentica.toml`, and depends on it by path:

```toml
[lib]
crate-type = ["cdylib"]

[dependencies]
agentica-native = { path = "../deps/native-gen/native/agentica-native" }
```

`build` makes the module; paths are from the package root:

```sh
agentica deps/native-gen/cli.agc build math.agc
```

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
