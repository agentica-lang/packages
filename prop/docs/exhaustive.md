---
title: Exhaustive check
description: Try every case up to a size, smallest first, instead of a random sample.
weight: 4
---

`Prop.exhaustive(gen, size, max_cases = 10_000, law)` tries every case that `gen` has up to `size`, smallest first. It returns `ok()` when all of them hold. `Prop.cases(gen, size)` says how many cases there are.

```agentica
def test_reverse_twice_up_to_size_3() -> Result[Void]
  return Prop.exhaustive(Prop.list(Prop.bool()), 3) do |xs|
    Prop.eq(xs.reverse.reverse, xs)
  end
end
```

`Prop.cases(Prop.list(Prop.bool()), 3)` is 15: the lists of up to 3 Bool.

A false law returns the counterexample of the smallest size that has one:

```agentica
result = Prop.exhaustive(Prop.list(Prop.int(0, 9)), 2) do |xs| Prop.eq(xs.reverse, xs) end
puts(result.message)
```

```text
falsified at size 2, counterexample [0,1]: expected [0,1], got [1,0]
```

A pass is "all N cases up to size k". It never means the law is proved, because a bigger size can still break it.

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

```text
Prop.exhaustive: 137257 cases up to size 6 is more than max_cases 10000
```

That is the error of `Prop.list(Prop.int(0, 9))` at size 6. The cases of a list grow as the power of its items, and a test has a step budget (see [Checking](checking.md)).

A case that is discarded with `Prop.assume` is skipped. A law that skips all of them is an error.

There is no seed and no `Config`: the cases are the same on every run.
