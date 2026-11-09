---
title: Laws
description: The common laws in one call, and how to state your own.
weight: 3
---

Each helper returns the `Result[Void]` of `check`, so it goes straight into a test. Each one takes a `Prop.Config` just before its last argument (as `check` does), which is optional. The last argument is a block or a `&function` reference.

| Law | Holds when |
|---|---|
| `Prop.roundtrip(gen, encode, decode)` | `decode(encode(x))` is `ok(x)`; `decode` returns a `Result`, as `JSON.decode` does |
| `Prop.idempotent(gen, f)` | `f(f(x))` is `f(x)` |
| `Prop.oracle(gen, fast, slow)` | `fast(x)` is `slow(x)`: the fast code against a simple one that is obviously right |
| `Prop.associative(gen, op)` | `op(op(a, b), c)` is `op(a, op(b, c))` |
| `Prop.commutative(gen, op)` | `op(a, b)` is `op(b, a)` |
| `Prop.preserves(gen, f, measure)` | `measure(f(x))` is `measure(x)`: the size, the sum, the sortedness |

```agentica {mode="fragment"}
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

def test_sort_is_idempotent() -> Result[Void]
  return Prop.idempotent(Prop.list(Prop.int(-9, 9)), Prop.Config(runs: 50)) do |xs| xs.sort end
end

def test_sum_against_a_loop() -> Result[Void]
  return Prop.oracle(Prop.list(Prop.int(-9, 9)), &fast_sum, &slow_sum)
end
```

A failure names the law and both values:

```agentica {mode="fragment"}
result = Prop.idempotent(Prop.list(Prop.int(-9, 9)), Prop.Config(seed: some(3))) do |xs| xs.reverse end
puts(result.message)
```

```text
falsified after 2 runs, shrunk to [0,-1], seed 3: f(f(x)) differs from f(x): expected [-1,0], got [0,-1]
```

Equality is `Prop.eq`: the values are compared as JSON, so they must be JSON-encodable, and two maps with the same pairs in a different order differ.

For a law that is not in the table, use `Prop.check` and return `Prop.eq(...)` or `error(...)`. See [Checking](checking.md).
