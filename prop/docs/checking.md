---
title: Checking
description: Prop.check, Prop.Config, Prop.eq and Prop.assume, then seeds, discarded cases and the rules for a law.
weight: 1
---

## Prop.check

```signature
Prop.check(gen: Gen[T], config: Config = Config(), law: Fn[T, Result[Void]]) -> Result[Void]
```

Runs `law` on `config.runs` values of `gen`. It returns `ok()` when the law holds for all of them, or an `error` with the shrunk counterexample, the number of runs and the seed.

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  puts(Prop.check(Prop.int(0, 100)) do |n| Prop.eq(n + 0, n) end)
  small = Prop.check(Prop.int(0, 100), Prop.Config(seed: some(7))) do |n|
    Prop.eq(n < 50, true)
  end

  puts(small.message)
end
```

```output
ok()
falsified after 3 runs, shrunk to 50, seed 7: expected true, got false
```

## Prop.Config

```signature
Prop.Config(runs: Int = 100, seed: Optional[Int] = none, discards: Int = 1000, shrinks: Int = 500)
```

How a check runs: how many cases, a fixed seed (32 bits; a bigger number is masked to them), how many discarded cases are too many, and how many laws to run when shrinking.

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  config = Prop.Config(runs: 3, seed: some(1))
  puts(Prop.check(Prop.int(0, 9), config) do |n| Prop.eq(n * 2, n + n) end)
end
```

```output
ok()
```

## Prop.eq

```signature
Prop.eq(actual: T, expected: T) -> Result[Void]
```

`ok()` when the two values encode to the same JSON, else an `error` that shows both. It is the equality for a law: its failure is a plain `Result`, so `check` can shrink it.

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  puts(Prop.eq([1, 2], [1, 2]))
  puts(Prop.eq([1, 2], [2, 1]))
end
```

```output
ok()
error("expected [2,1], got [1,2]")
```

## Prop.assume

```signature
Prop.assume(condition: Bool) -> Result[Void]
```

`ok()` when `condition` is true. When it is false, the case is discarded: it is neither a pass nor a failure. Use it first in a law, with `try`.

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  result = Prop.check(Prop.int(-50, 50)) do |n|
    try Prop.assume(n != 0)
    Prop.eq(n * 100 / n, 100)
  end

  puts(result)
end
```

```output
ok()
```

## Seeds and replay

`check` draws its seed from the `Random` of the test, so `agentica --seed N test` replays the whole run. A case depends on its seed alone. The seed of a failure is in its message, and `Prop.Config(seed: some(S))` runs that check again, and nothing else. `Prop.sample` (on the [generators](generators.md) page) shows the values that a seed makes.

## Discarded cases

`check` fails when more than `config.discards` cases are discarded, so a law cannot pass without being tried:

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  config = Prop.Config(discards: 5, seed: some(1))
  result = Prop.check(Prop.int(0, 9), config) do |n|
    try Prop.assume(n > 100)
    ok()
  end

  puts(result.message)
end
```

```output
gave up: 6 cases discarded and 0 of 100 passed, seed 1
```

## Shrinking

When a case fails, `check` tries simpler values of the same generator and keeps the simplest one that still fails. Each generator shrinks in its own way (see [generators](generators.md)). `config.shrinks` bounds the laws run to shrink one case; when it runs out, the message says `(shrinking stopped after N steps)`.

## Rules for a law

- Fail with `Prop.eq`, `Prop.assume` or `error(...)`. A failed `Test.eq` or `Test.assert` inside a law fails the test at the first failing case, before `check` can shrink it.
- Do not narrow a generator, or weaken the law, to make it pass. Put the counterexample in a plain `test_` function and fix the code.
- `Prop.eq` uses `JSON.encode`, so what it compares must be JSON-encodable (compare `bytes.to_a` for `Bytes`). Two maps with the same pairs in another order differ. The counterexample is written by the generator, so a generated type that JSON cannot encode (`Prop.bytes`, or a struct with bytes through `Prop.map_shown`) is reported too.
- A test has a budget of about 2.5 million steps (and 30 seconds). A run that goes over it ends with `RUNTIME-STEP-LIMIT`, which `check` cannot catch, so the counterexample and the seed are lost. Making a case costs about 200 steps per item (a string is a list of characters, so a list of strings is a list of lists): 100 cases of `Prop.list(Prop.string())` take about 0.5 million steps before the law runs, of `Prop.list(Prop.int(0, 1000), 100)` about 0.7 million, and of `Prop.list(Prop.string(20), 20)` about 1.5 million. A case of a `Tree` (a value and a list of trees) from `Prop.of` takes about 4000 steps at depth 2 and 7000 at depth 3. Raise `max_size` or `runs` only as far as that allows, or split the law into several tests.
