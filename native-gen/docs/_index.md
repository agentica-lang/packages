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
  stats_Summary summary = {count, min, max, total / count};
  return an_some(env, stats_Summary_make(env, &summary));
}

an_term stats_rows(an_env *env, ng_str text) {
  /* text.data, text.len; a cell is stats_Cell_Empty(env), stats_Cell_Number(env, x) or stats_Cell_Text(env, s) */
}

STATS_NATIVE_MODULE(NULL)
```

A function you did not write is a link error, not a failure when the module loads. Other `.c` files of the module include the header without the define and get the prototypes and constants only; the implementation part has its own guard, so the one file may include the header before the define too.

## The header

- The prefix of the C names is the library name of the block up to its first `.` (`stats`), or `--prefix NAME`. Macros and constants use it in capitals. `an`, `agentica` and a prefix that starts with `an_` belong to the C API and are refused.
- One prototype per function, `an_term PREFIX_name(an_env *env, ...)`, with the `##` doc above it. `Int` is `int64_t`, `Float` `double`, `Bool` `bool`, `String` `ng_str` and `Bytes` `ng_buf` (`data` and `len`, borrowed for the call: copy them to keep them). A struct or enum of the program is its C value (below). Other types (`List`, `Map`, `Optional`, `Result`, resources) are an `an_term`, which the getters of `agentica_native.h` read. The result is always an `an_term`.
- Each wrapper checks the arguments in order and fails the call at the first one that does not decode: a scalar with `an_badarg(env, i)`, a struct or enum with the path of its bad part (`argument 1: Shape.Circle.0.x: expected Int`).
- `def` is `AN_SHORT` and `compute def` is `AN_DIRTY`.
- `PREFIX_TYPE_Name` is the row of a struct or enum, the `TYPE` of `an_struct` and `an_enum`; `PREFIX_Name_member` is a field or variant, in declared order. `PREFIX_RESOURCE_Name` is the row of a resource.
- A struct is `typedef struct {...} PREFIX_Name`, a field by its name (a C keyword gets a trailing `_`). An enum is a `tag` of type `PREFIX_Name_tag` (`PREFIX_Name_Variant`, so a `switch` on it is checked by `-Wswitch`) and a union `as` with one struct per variant that has a payload, `_0`, `_1`, ... in order: `shape.as.Circle._1`. A field or payload of another struct or enum of the block is embedded by value, unless that type leads back to its owner (a recursive enum), where it is an `an_term`.
- For a type that a parameter reaches, `bool PREFIX_Name_get(env, term, &out)` reads a term into its C value; on false the call has already failed, with the path of the bad part. For a type that a result reaches, `PREFIX_Name_make(env, &value)` makes the term, and an enum has one constructor per variant, `PREFIX_Shape_Circle(env, center, radius)`. Strings and Bytes in a C value are borrowed and terms last for the call: keep C values in locals.
- A resource needs `struct PREFIX_Name_state` and `PREFIX_Name_FREE` (a `void (*)(void *state)`, or `NULL`), both defined before `PREFIX_NATIVE_MODULE`. C11 has no empty struct: a resource with no state still needs one member.
- Names: `empty?` is `PREFIX_empty_p` and `save!` is `PREFIX_save_bang`. A parameter that is a C or C++ keyword, `env`, a type or macro a prototype may use (`int64_t`, `size_t`, `uint8_t`, `uint32_t`, `errno`), or that starts with `an_` or `ng_`, gets a trailing `_` (`int_`). The header compiles as C11 and as C++.
- The header starts with a check of the version of `agentica_native.h`: it stops the build when the API is older than the block needs.

## Errors

An error is one line on stderr, `native-gen: [CODE] message`, and the exit code is 1. Bad usage prints the usage error and a `Try 'native-gen --help'` line, and the exit code is 2.

| Code | When |
|---|---|
| `NATIVE-GEN-NAME` | two names map to one C identifier (`empty?` and `empty_p`) |
| `NATIVE-GEN-BLOCK` | the file has no `extern module` block, or more than one |
| `NATIVE-GEN-PREFIX` | the prefix is not a C identifier, or is the C API's; give another with `--prefix` |
| `NATIVE-GEN-UNKNOWN` | `std/analysis` gives a function mode or a type kind that this version does not know |
| `NATIVE-GEN-STALE` | `--check`: the file at `--output` is not the header that the `.agc` gives |
| `NATIVE-GEN-IO` | the header cannot be read or written |
| any other | the code of the diagnostic when the `.agc` does not check |

## Check in CI

Commit the header, and fail the build when it is stale:

```sh
agentica deps/native-gen/cli.agc stats.agc --output native/stats_native.h --check
```

From a program, `NativeGen.header(path, prefix = "")` from `import NativeGen from "pkg/native-gen/native_gen"` returns the text of the header.
