# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

Needs Agentica 0.25.0 or later.

### Added

- `Prop.check(gen, config, law)`: runs a law on generated values, shrinks the first failing one, and returns `error("falsified after N runs, shrunk to X, seed S: ...")`. The seed comes from the test's `Random` (`agentica --seed N test` replays the run) or from `Prop.Config(seed: some(S))`.
- The generators `int`, `float`, `bool`, `string`, `list`, `optional`, `one_of`, `map` and `pair`, with shrinking (an Int toward 0, a list to fewer items and then smaller ones), and `Prop.sample` to look at the cases of a seed.
- `Prop.assume` discards a case, and `check` fails when more than `Config.discards` are discarded. `Prop.eq` is the equality for a law, a plain `Result` that can be shrunk.
