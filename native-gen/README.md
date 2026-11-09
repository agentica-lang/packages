# native-gen

The C header of an Agentica `extern module` block. Write plain C functions with C types; the wrappers that check the
arguments, the codecs of your structs, enums, Lists, Maps, Optionals and Results, and the tables of the module are
generated from the `.agc`, the one source of every signature.

Needs Agentica 0.27.0 or later. Add it to `agentica.toml` and run `agentica install`:

```toml
[dependencies]
native-gen = { git = "https://github.com/agentica-lang/packages", tag = "native-gen-0.1.0", subdir = "native-gen" }
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
header and its `agentica.toml` entry.

The docs, with every C name, the header layout and the error codes:
<https://agentica-lang.github.io/packages/native-gen/>.
