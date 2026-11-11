# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- **Breaking:** needs Agentica 0.30.0 or later: the sources are formatted with `agentica fmt` of 0.30.0, which uses its syntax (implicit returns, guards, one-line defs). CI tests with Agentica 0.30.0.

## [0.2.0] - 2026-11-10

Needs Agentica 0.27.0 or later.

### Added

- `cli.agc FILE --lang rust --output FILE.rs` writes the Rust side of the block on the `agentica-native` crate: a type with its codecs per struct and enum, the trait `PREFIXNative` (`--prefix MyDb` keeps its case) with one method per function (each takes `env` and returns `Result<T, Raise>`; a resource is an associated type, held as `ResourceArc`), and `module::<Impl>()` for `agentica_native::export!`. A payload that leads back to its own type stays a term (`TreeTerm<'a>`).
- `cli.agc build FILE` builds a Rust module from the crate `rust/` at the package root (the nearest folder up from FILE with an `agentica.toml`): it writes `rust/src/NAME_native.rs`, runs `cargo build --release`, copies the library to `native/` and adds the `[native.NAME]` entry to `agentica.toml` when it is missing. `build --check` fails (`NATIVE-GEN-STALE`) when the Rust file is stale; `NATIVE-GEN-CARGO` when cargo is missing or fails.
- `cli.agc new --lang rust NAME` starts a Rust module: `NAME.agc` and the crate `rust/`, with one method per function that fails the call until you write it. `build` then builds it.

### Changed

- The crate `agentica-native` is in `native/agentica-native`, which `agentica install` copies into `deps/native-gen/`.
- A bad item of a `List` or `Map` argument now fails the call with `argument N:` before its path, as a bad argument does (`argument 1: List[Int].2: expected Int`), also inside an item, an `Optional` or a `Result`. A cursor of `_open` keeps the plain path.

## [0.1.0] - 2026-11-09

Needs Agentica 0.27.0 or later.

### Added

- `cli.agc FILE --output HEADER` writes the C header of the `extern module` block of FILE: one typed prototype per function (`Int` is `int64_t`, `Float` `double`, `Bool` `bool`, `String` `ng_str` and `Bytes` `ng_buf`, borrowed; a struct or enum its C value; a resource its state, `struct PREFIX_Name_state *`), the `##` docs above them, the row enums of the type and resource tables, and under `PREFIX_NATIVE_IMPLEMENTATION` the wrappers that check each argument and the tables, which `PREFIX_NATIVE_MODULE(LOAD)` ends the file with. Signatures, shapes and modes come from `std/analysis`; `def` is `AN_SHORT` and `compute def` `AN_DIRTY`.
- C names: `empty?` is `PREFIX_empty_p`, `save!` `PREFIX_save_bang`, a parameter that is a C or C++ keyword (or `env`, `size_t`, `errno`, an `an_` name) gets a trailing `_`, and two names that map to one C identifier are an error (`NATIVE-GEN-NAME`).
- Structs and enums of the block are C values: `typedef struct {...} PREFIX_Summary`, and for an enum a `tag` (checked by `-Wswitch`) with a union of payloads. `PREFIX_Name_get` reads a term for the types that parameters reach; `PREFIX_Name_make` and one constructor per variant (`PREFIX_Cell_Number(env, x)`) make one for the types that results reach. A failed read fails the call with the path of the bad part (`Shape.Circle.0.x: expected Int`). A recursive type keeps the payloads that lead back to it as terms.
- `List` and `Map` parameters are cursors (`PREFIX_list_Float_next` gives 1, 0 at the end, -1 for a bad item, with its path: `List[Int].1: expected Int`), never copied to an array; `_open` opens a term. A `List` or `Map` result has a builder (`_begin`, `_push` or `_put`, `_end`).
- `Optional` and `Result` parameters are structs (`some` or `ok`, `value`, and the `error` message of a Result); `_get` reads a term into one. Results have `PREFIX_optional_T_some` and `PREFIX_result_T_ok`, beside `an_none` and `an_error`.
- Resources: a parameter is its state; `PREFIX_Name_new(env, &out)` makes one, and `PREFIX_Name_get(env, term)` gives the state of a resource that is an argument of the call, NULL otherwise.
- `cli.agc new NAME` (or `FOLDER/NAME`) starts a module that builds and loads, with its `agentica.toml` entry; it writes only new files (`NATIVE-GEN-EXISTS`, `NATIVE-GEN-MANIFEST`).
- `--check` fails (`NATIVE-GEN-STALE`) when the committed header is not the one the file gives. The header starts with a check of the native API version it needs.
