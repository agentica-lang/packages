---
title: native-gen
description: The C header of an extern module block. Write plain C functions with C types; the wrappers, the argument checks and the tables of the module are generated from the .agc.
---

`native-gen` reads the `extern module` block of an `.agc` file and writes a C header for it. The C author writes plain functions with C types; the header has their prototypes, and the wrappers that check the arguments and the function and type tables of the module. The `.agc` is the one source: every signature and shape comes from `std/analysis`, the same text that the VM compares with the tables when it loads the module.

## Install

Needs Agentica 0.27.0 or later. Add it to `agentica.toml` with the prefixed tag of the release, and run `agentica install`:

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

an_term stats_summary(an_env *env, an_term values) {
  /* ... */
  an_term fields[4];
  fields[STATS_Summary_count] = an_int(env, count);
  /* ... */
  return an_some(env, an_struct(env, STATS_TYPE_Summary, fields));
}

an_term stats_rows(an_env *env, an_str text) { /* text.data, text.len */ }

STATS_NATIVE_MODULE(NULL)
```

A function you did not write is a link error, not a failure when the module loads. Other `.c` files of the module include the header without the define and get the prototypes and constants only.

## The header

- The prefix of the C names is the library name of the block up to its first `.` (`stats`), or `--prefix NAME`. Macros and constants use it in capitals.
- One prototype per function, `an_term PREFIX_name(an_env *env, ...)`, with the `##` doc above it. `Int` is `int64_t`, `Float` `double`, `Bool` `bool`, `String` `an_str` and `Bytes` `an_buf` (`data` and `len`, borrowed for the call: copy them to keep them). Other types (`List`, `Map`, `Optional`, `Result`, structs, enums, resources) are an `an_term`, which the getters of `agentica_native.h` read. The result is always an `an_term`.
- Each wrapper checks the arguments in order and answers `an_badarg(env, i)` for the first one that does not decode.
- `def` is `AN_SHORT` and `compute def` is `AN_DIRTY`.
- `PREFIX_TYPE_Name` is the row of a struct or enum, the `TYPE` of `an_struct` and `an_enum`; `PREFIX_Name_member` is a field or variant, in declared order. `PREFIX_RESOURCE_Name` is the row of a resource.
- A resource needs `struct PREFIX_Name_state` and `PREFIX_Name_FREE` (a `void (*)(void *state)`, or `NULL`), both defined before `PREFIX_NATIVE_MODULE`.
- Names: `empty?` is `PREFIX_empty_p` and `save!` is `PREFIX_save_bang`. A parameter that is a C or C++ keyword, or `env`, gets a trailing `_` (`int_`). The header compiles as C11 and as C++.
- The header starts with a check of the version of `agentica_native.h`: it stops the build when the API is older than the block needs.

## Errors

An error is one line on stderr, `native-gen: [CODE] message`, and the exit code is 1 (2 for bad usage):

| Code | When |
|---|---|
| `NATIVE-GEN-NAME` | two names map to one C identifier (`empty?` and `empty_p`) |
| `NATIVE-GEN-BLOCK` | the file has no `extern module` block, or more than one |
| `NATIVE-GEN-PREFIX` | the prefix is not a C identifier; give one with `--prefix` |
| `NATIVE-GEN-STALE` | `--check`: the file at `--output` is not the header that the `.agc` gives |
| `NATIVE-GEN-IO` | the header cannot be read or written |
| any other | the code of the diagnostic when the `.agc` does not check |

## Check in CI

Commit the header, and fail the build when it is stale:

```sh
agentica deps/native-gen/cli.agc stats.agc --output native/stats_native.h --check
```

From a program, `NativeGen.header(path, prefix = "")` from `import NativeGen from "pkg/native-gen/native_gen"` returns the text of the header.
