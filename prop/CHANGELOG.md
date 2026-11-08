# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
