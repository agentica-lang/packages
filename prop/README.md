# prop

Property-based testing for Agentica: state a law, check it on many generated inputs, and get the smallest input that
breaks it. Pure Agentica, no compiler change; it runs in `agentica test` as it is.

```toml
[dependencies]
prop = { git = "https://github.com/agentica-lang/packages", tag = "prop-0.1.0", subdir = "prop" }
```

```ruby
import Prop from "pkg/prop/prop"

def test_reverse_twice() -> Result[Void]
  return Prop.check(Prop.list(Prop.int(-100, 100))) do |xs|
    Prop.eq(xs.reverse.reverse, xs)
  end
end
```

A false law fails the test with the shrunk counterexample:
`falsified after 37 runs, shrunk to [3,0], seed 1234: expected [0,3], got [3,0]`.

## API

| | |
|---|---|
| `Prop.check(gen, config, law)` | runs `law` (a block that returns `Result[Void]`) on 100 values of `gen`; `config` is optional |
| `Prop.Config(runs: 100, seed: none, discards: 1000)` | how many cases, a fixed seed, how many discarded cases are too many |
| `Prop.eq(actual, expected)` | the equality for a law: `ok()`, or an `error` with both values (compared as JSON) |
| `Prop.assume(condition)` | discards the case when `condition` is false; `check` fails when more than `discards` are discarded, so a law cannot pass without being tried |
| `Prop.int(min, max)`, `Prop.float(min, max)`, `Prop.bool()` | scalars; an Int shrinks toward 0 (or the bound nearest to it) |
| `Prop.string(max_size = 20)`, `Prop.list(gen, max_size = 20)` | shrink to a shorter value, then to smaller items (a string toward `"a"`) |
| `Prop.optional(gen)`, `Prop.one_of(items)`, `Prop.pair(a, b)` | `none` (one in four) or `some`; one item, shrinking toward the first; a `Prop.Pair(first, second)` |
| `Prop.map(gen, f)` | the values of `gen` through `f`; they shrink as the originals do |
| `Prop.sample(gen, seed, count = 5)` | the values that `check` would try first with that seed |

`Gen[T]` makes a shrink tree (a value and, on demand, its simpler values) from a seed, so `map` and `pair` shrink with no
inverse function.

## Seeds and replay

`check` draws its seed from the test's `Random`, so `agentica --seed N test` replays the whole run, and a case depends on
its seed alone. The seed of a failure is in the message: `Prop.Config(seed: some(1234))` runs that check again and
nothing else. Report a result as "tested with N cases, seed S", never as proved.

## Rules for a law

- Fail with `Prop.eq`, `Prop.assume` or `error(...)`. A failed `Test.eq` or `Test.assert` inside a law fails the test at
  the first failing case, before `check` can shrink it.
- Do not narrow a generator, or weaken the law, to make it pass: put the counterexample in a plain `test_` and fix the
  code.
- A test has a step budget and 30 s. The default of 100 cases is small on purpose; raise `runs` only when the law is
  cheap.
- `Prop.eq` and the counterexample use `JSON.encode`, so the generated type must be JSON-encodable, and two maps with the
  same pairs in another order differ.
