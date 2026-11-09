# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

Needs Agentica 0.27.0 or later.

### Added

- `cli.agc FILE --output HEADER` writes the C header of the `extern module` block of FILE: one typed prototype per function (`Int` is `int64_t`, `Float` `double`, `Bool` `bool`, `String` `ng_str` and `Bytes` `ng_buf`, borrowed; a struct or enum its C value; other types `an_term`), the `##` docs above them, the row enums of the type and resource tables, and under `PREFIX_NATIVE_IMPLEMENTATION` the wrappers that check each argument and the tables, which `PREFIX_NATIVE_MODULE(LOAD)` ends the file with. Signatures, shapes and modes come from `std/analysis`; `def` is `AN_SHORT` and `compute def` `AN_DIRTY`.
- C names: `empty?` is `PREFIX_empty_p`, `save!` `PREFIX_save_bang`, a parameter that is a C or C++ keyword (or `env`, `size_t`, `errno`, an `an_` name) gets a trailing `_`, and two names that map to one C identifier are an error (`NATIVE-GEN-NAME`).
- Structs and enums of the block are C values: `typedef struct {...} PREFIX_Summary`, and for an enum a `tag` (checked by `-Wswitch`) with a union of payloads. `PREFIX_Name_get` reads a term for the types that parameters reach; `PREFIX_Name_make` and one constructor per variant (`PREFIX_Cell_Number(env, x)`) make one for the types that results reach. A failed read fails the call with the path of the bad part (`Shape.Circle.0.x: expected Int`). A recursive type keeps the payloads that lead back to it as terms.
- `--check` fails (`NATIVE-GEN-STALE`) when the committed header is not the one the file gives. The header starts with a check of the native API version it needs.
