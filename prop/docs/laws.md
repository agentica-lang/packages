---
title: Laws
description: The common laws in one call each, with an example, then how equality works and how to state your own law.
weight: 3
---

Each law returns the `Result[Void]` of `Prop.check`, so it goes straight into a test. Each one takes an optional `Prop.Config` just before its last argument, as `check` does. The functions it takes are blocks or `&function` references.

## Prop.roundtrip

```signature
Prop.roundtrip(gen: Gen[T], encode: Fn[T, E], config: Config = Config(), decode: Fn[E, Result[T]]) -> Result[Void]
```

`decode(encode(x))` is `ok(x)`. `decode` returns a `Result`, as `JSON.decode` does; an `error` breaks the law.

```agentica
import Prop from "pkg/prop/prop"

def show(n: Int) -> String
  return n.to_s
end

def parse(text: String) -> Result[Int]
  return text.to_i
end

def main() -> Void
  puts(Prop.roundtrip(Prop.int(-1000, 1000), &show, &parse))
end
```

```output
ok()
```

## Prop.idempotent

```signature
Prop.idempotent(gen: Gen[T], config: Config = Config(), f: Fn[T, T]) -> Result[Void]
```

`f(f(x))` is `f(x)`: running `f` again changes nothing.

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  puts(Prop.idempotent(Prop.list(Prop.int(-9, 9))) do |xs| xs.sort end)
  reversed = Prop.idempotent(Prop.list(Prop.int(-9, 9)), Prop.Config(seed: some(3))) do |xs| xs.reverse end
  puts(reversed.message)
end
```

```output
ok()
falsified after 2 runs, shrunk to [0,-1], seed 3: f(f(x)) differs from f(x): expected [-1,0], got [0,-1]
```

## Prop.oracle

```signature
Prop.oracle(gen: Gen[A], fast: Fn[A, B], config: Config = Config(), slow: Fn[A, B]) -> Result[Void]
```

`fast(x)` is `slow(x)`: the fast code against a simple one that is obviously right.

```agentica
import Prop from "pkg/prop/prop"

def fast_sum(xs: List[Int]) -> Int
  return xs.sum
end

def slow_sum(xs: List[Int]) -> Int
  total = 0
  for x in xs
    total += x
  end

  return total
end

def main() -> Void
  puts(Prop.oracle(Prop.list(Prop.int(-9, 9)), &fast_sum, &slow_sum))
end
```

```output
ok()
```

## Prop.associative

```signature
Prop.associative(gen: Gen[T], config: Config = Config(), op: Fn[T, T, T]) -> Result[Void]
```

`op(op(a, b), c)` is `op(a, op(b, c))`.

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  puts(Prop.associative(Prop.string(3)) do |a, b| a + b end)
end
```

```output
ok()
```

## Prop.commutative

```signature
Prop.commutative(gen: Gen[T], config: Config = Config(), op: Fn[T, T, T]) -> Result[Void]
```

`op(a, b)` is `op(b, a)`.

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  puts(Prop.commutative(Prop.int(-9, 9)) do |a, b| a * b end)
  joined = Prop.commutative(Prop.string(3), Prop.Config(seed: some(1))) do |a, b| a + b end
  puts(joined.message)
end
```

```output
ok()
falsified after 5 runs, shrunk to {"a":"a","b":"b"}, seed 1: op(a, b) differs from op(b, a): expected "ba", got "ab"
```

## Prop.preserves

```signature
Prop.preserves(gen: Gen[T], f: Fn[T, T], config: Config = Config(), measure: Fn[T, M]) -> Result[Void]
```

`measure(f(x))` is `measure(x)`: `f` keeps the size, the sum, the sortedness, or whatever `measure` reads.

```agentica
import Prop from "pkg/prop/prop"

def reverse(xs: List[Int]) -> List[Int]
  return xs.reverse
end

def total(xs: List[Int]) -> Int
  return xs.sum
end

def main() -> Void
  puts(Prop.preserves(Prop.list(Prop.int(-9, 9)), &reverse, &total))
end
```

```output
ok()
```

## Equality and your own laws

A law compares with `Prop.eq`: the values are compared as JSON, so they must be JSON-encodable, and two maps with the same pairs in a different order differ. This is why a law refuses a generator of `Bytes` (or of a struct with a `Bytes` field) with `CHECK-NOT-ENCODABLE`, though `Prop.check` accepts it. For bytes, state the law with `Prop.check` and compare with `==` or `bytes.to_a`. A failure names the law and both values, as `f(f(x)) differs from f(x)` above.

For a law that is not here, use `Prop.check` and return `Prop.eq(...)` or `error(...)`. See [Checking](checking.md).
