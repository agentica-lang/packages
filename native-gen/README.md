# native-gen

The C header of an Agentica `extern module` block. Write plain C functions with C types; the wrappers that check the
arguments, the codecs of your structs, enums, Lists, Maps, Optionals and Results, and the tables of the module are
generated from the `.agc`, the one source of every signature.

Needs Agentica 0.30.0 or later. Add it with the prefixed tag of the release, in a project with an `agentica.toml`:

```sh
agentica add native-gen https://github.com/agentica-lang/packages --tag native-gen-0.2.0 --subdir native-gen
```

That writes this line of `agentica.toml`, and the entry of `agentica.lock`:

```toml
[dependencies]
native-gen = { git = "https://github.com/agentica-lang/packages", tag = "native-gen-0.2.0", subdir = "native-gen" }
```

Before, each C function takes terms and checks them by hand:

```c
an_term stats_summary(an_env *env, an_term values) { /* an_list_cursor_begin, an_get_float, an_badarg ... */ }
```

After, it takes C types, and a bad value fails the call with its path (`List[Float].2: expected Float`):

```c
an_term stats_summary(an_env *env, stats_list_Float values) { /* stats_list_Float_next(env, &values, &x) */ }
```

Make the header, and check it in CI:

```sh
agentica deps/native-gen/cli.agc stats.agc --output native/stats_native.h
agentica deps/native-gen/cli.agc stats.agc --output native/stats_native.h --check
```

`agentica deps/native-gen/cli.agc new demo` starts a module that builds and loads: `demo.agc`, `native/demo.c`, its
header and its `agentica.toml` entry. `new --lang rust demo` starts one in Rust: `demo.agc` and the crate
`rust/`.

A module in Rust: `agentica deps/native-gen/cli.agc build math.agc` writes the Rust side of the block into the crate
`rust/`, runs `cargo build --release`, copies the library to `native/` and adds its `agentica.toml` entry.
[examples/rust_math](examples/rust_math) is a whole package (an `.agc` with structs both ways, its `rust/src/lib.rs`
and `Cargo.toml`); the docs walk through it.

The docs, with every C name, the header layout and the error codes:
<https://agentica-lang.github.io/packages/native-gen/>.
