# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.4.0] - 2026-11-13

Needs Agentica 0.31.0.

### Added

- `Prop.bytes(min, max)` makes `Bytes`, which shrink to fewer and smaller bytes. A counterexample of bytes is reported as the list of their values.
- `Prop.non_empty_list(gen, max_size)` makes lists of at least one item, which never shrink to the empty list. With `Prop.int(1, 12)` it is the sizes of the pieces that cut a sequence, so a law can try any cut.
- `Prop.map_shown(gen, show, f)` is `Prop.map` for a result that JSON cannot encode, such as a struct with a `Bytes` field.
- The docs say how to write `Gen` and `Pair` bare: `import {Gen, Pair} from "pkg/prop/prop"`.

### Changed

- **Breaking:** a `Gen` has a `show` field, the text of a value in a counterexample, so a `Gen(...)` built by hand needs `show: ...`. `Prop.check` and `Prop.exhaustive` no longer need the generated type to be JSON-encodable; the six laws, `Prop.eq`, `Prop.map` and `Prop.one_of` still do. The text of every other generator is what `JSON.encode` gave.

## [0.3.0] - 2026-11-13

Needs Agentica 0.31.0.

### Changed

- **Breaking:** needs Agentica 0.31.0, and `agentica = "0.31.0"` in the manifest says so: `Prop.of` takes a `JSON.Value` (the new name of `Json`), and the sources use `private` instead of `export`. The public names of every module are the same. CI tests with Agentica 0.31.0.

## [0.3.0-alpha.1] - 2026-11-12

Needs Agentica 0.31.0-alpha.1.

### Changed

- **Breaking:** needs Agentica 0.31.0-alpha.1: the sources are formatted with its `agentica fmt`. CI tests with Agentica 0.31.0-alpha.1.

## [0.2.1] - 2026-11-12

Needs Agentica 0.30.0 or later.

### Fixed

- The sources compile with the next Agentica, which refuses a method call right after the `end` of a `do` block (`CHECK-CHAIN-AFTER-END`); they still need Agentica 0.30.0 or later.

## [0.2.0] - 2026-11-11

Needs Agentica 0.30.0 or later.

### Changed

- **Breaking:** needs Agentica 0.30.0 or later: the sources are formatted with `agentica fmt` of 0.30.0, which uses its syntax (implicit returns, guards, one-line defs). CI tests with Agentica 0.30.0.
- The docs open with a runnable example, and every function has its signature and a short example.

## [0.1.0] - 2026-11-08

Needs Agentica 0.25.0 or later.

### Added

- `Prop.check(gen, config, law)`: runs a law on generated values, shrinks the first failing one, and returns `error("falsified after N runs, shrunk to X, seed S: ...")`. The seed comes from the test's `Random` (`agentica --seed N test` replays the run) or from `Prop.Config(seed: some(S))`. `Config.shrinks` bounds the laws run to shrink; the message says when it stopped.
- The generators `int`, `float`, `bool`, `string`, `list`, `optional`, `one_of`, `map` and `pair`, with shrinking (an Int toward 0, a list to fewer items and then smaller ones), and `Prop.sample` to look at the cases of a seed.
- `Prop.assume` discards a case, and `check` fails when more than `Config.discards` are discarded. `Prop.eq` is the equality for a law, a plain `Result` that can be shrunk.
- The laws `Prop.roundtrip`, `idempotent`, `oracle`, `associative`, `commutative` and `preserves`, one call each, with an optional `Config`; a failure names the law and both values.
- `Prop.of(T.codec, JSON.schema(T))`: a generator for a struct or enum that JSON can decode (nested structs, enums, `Optional`, lists, maps, recursive types up to `depth`), shrinking through its parts.
- `Prop.exhaustive(gen, size, max_cases, law)` tries every case up to a size, smallest first, and `Prop.cases(gen, size)` counts them; it reports "all N cases up to size k", never "proved".
- An agent guide in the README: a law per public function, the shrunk counterexample as a plain `test_`, never weaken the law, report "tested with N cases, seed S, discards D".
