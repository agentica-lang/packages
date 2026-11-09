---
title: Checking
description: Prop.check, the config, seeds and replay, discarding cases, and the rules for a law.
weight: 1
---

## Prop.check

```agentica {mode="fragment"}
Prop.check(gen, config, law)
```

`check` draws `config.runs` values from `gen` and runs `law` on each one. A law is a block (or a `&function` reference) that takes the value and returns a `Result[Void]`. `check` returns `ok()` when all of them are `ok()`.

When one case fails, `check` shrinks it: it tries simpler values of the same generator and keeps the simplest one that still fails. It returns an `error` with the shrunk value, the number of runs, the seed and the message of the law:

```text
falsified after 1 run, shrunk to [0,-1], seed 1234: expected [0,-1], got [-1,0]
```

## Config

`Prop.Config` sets how a check runs. The fields have these defaults:

| Field | Default | What it is |
|---|---|---|
| `runs` | 100 | how many cases to try |
| `seed` | `none` | a fixed seed (32 bits; a bigger number is masked to them) |
| `discards` | 1000 | how many discarded cases are too many |
| `shrinks` | 500 | how many laws to run when shrinking; the message says `(shrinking stopped after N steps)` when it runs out |

```agentica {mode="fragment"}
config = Prop.Config(runs: 300, seed: some(1234))
```

## Seeds and replay

`check` draws its seed from the `Random` of the test, so `agentica --seed N test` replays the whole run. A case depends on its seed alone.

The seed of a failure is in its message. `Prop.Config(seed: some(1234))` runs that check again, and nothing else. Use `Prop.sample(gen, seed, count)` to look at the values that a seed makes:

```agentica {mode="fragment"}
puts(Prop.sample(Prop.int(0, 9), 1234, 5))
```

```text
[6, 6, 0, 4, 2]
```

## Discarding a case

`Prop.assume(condition)` returns `ok()` when the condition is true. When it is false, the case is discarded: it does not count as a pass or as a failure. Put it at the start of a law, with `try`:

```agentica {mode="fragment"}
def test_division() -> Result[Void]
  return Prop.check(Prop.int(-50, 50)) do |n|
    try Prop.assume(n != 0)
    Prop.eq(100 / n * n <= 100, true)
  end
end
```

`check` fails when more than `config.discards` cases are discarded, so a law cannot pass without being tried. With `discards: 50` and a law that discards every case:

```text
gave up: 51 cases discarded and 0 of 100 passed, seed S
```

## Rules for a law

- Fail with `Prop.eq`, `Prop.assume` or `error(...)`. A failed `Test.eq` or `Test.assert` inside a law fails the test at the first failing case, before `check` can shrink it.
- Do not narrow a generator, or weaken the law, to make it pass. Put the counterexample in a plain `test_` function and fix the code.
- `Prop.eq` and the counterexample use `JSON.encode`, so the generated type must be JSON-encodable. Two maps with the same pairs in another order differ.
- A test has a budget of about 2.5 million steps (and 30 seconds). A run that goes over it ends with `RUNTIME-STEP-LIMIT`, which `check` cannot catch, so the counterexample and the seed are lost. Making a case costs about 200 steps per item (a string is a list of characters), so 100 cases of `Prop.list(Prop.string())` take about 0.5 million steps before the law runs. Raise `max_size` or `runs` only as far as that allows, or split the law into several tests.
