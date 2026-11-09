---
title: Exhaustive check
description: Prop.exhaustive and Prop.cases, then what a size means for each generator and the limits.
weight: 4
---

An exhaustive check tries every case up to a size, smallest first, instead of a random sample. There is no seed and no `Config`: the cases are the same on every run.

## Prop.exhaustive

```signature
Prop.exhaustive(gen: Gen[T], size: Int, max_cases: Int = 10_000, law: Fn[T, Result[Void]]) -> Result[Void]
```

Runs `law` on every case of `gen` up to `size`. It returns `ok()` when all of them hold, or an `error` with the counterexample of the smallest size that has one.

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  puts(Prop.exhaustive(Prop.list(Prop.bool()), 3) do |xs| Prop.eq(xs.reverse.reverse, xs) end)
  result = Prop.exhaustive(Prop.list(Prop.int(0, 9)), 2) do |xs| Prop.eq(xs.reverse, xs) end
  puts(result.message)
end
```

```output
ok()
falsified at size 2, counterexample [0,1]: expected [0,1], got [1,0]
```

A pass means "all N cases up to size k", with N from `Prop.cases`. It never means the law is proved: a bigger size can still break it.

## Prop.cases

```signature
Prop.cases(gen: Gen[T], size: Int) -> Int
```

How many cases `Prop.exhaustive` tries for `gen` up to `size`. The count stops at 1000000000.

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  puts(Prop.cases(Prop.list(Prop.bool()), 3))
  puts(Prop.cases(Prop.int(-100, 100), 2))
end
```

```output
15
5
```

## What a size means

| Generator | Size k |
|---|---|
| `Prop.int`, `Prop.float` | up to k away from the value nearest to 0 (a Float on the whole numbers) |
| `Prop.list` | up to k items, each at size k |
| `Prop.string` | up to k characters, from the first k + 1 letters |
| `Prop.optional` | `none`, or a value at size k |
| `Prop.pair`, `Prop.of` | every combination |
| `Prop.one_of`, `Prop.bool` | all their values at every size |

For a struct from `Prop.of`, a map goes over the maps that hold or leave out each of the keys `"a"`, `"b"` and `"é 漢"`, so two cases are never the same map.

## Limits

`max_cases` is checked before anything runs. A size with more cases is an `error` that says how many ("at least 1000000000" when the count hit its cap):

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  result = Prop.exhaustive(Prop.list(Prop.int(0, 9)), 6) do |xs| Prop.eq(xs, xs) end
  puts(result.message)
end
```

```output
Prop.exhaustive: 137257 cases up to size 6 is more than max_cases 10000
```

The cases of a list grow as the power of its items, and a test has a step budget (see [Checking](checking.md)). A case that is discarded with `Prop.assume` is skipped, and a law that skips all of them is an error.
