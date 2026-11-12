---
title: prop
description: Property-based testing. State a law, check it on many generated inputs, and get the smallest input that breaks it.
---

`prop` checks a law on many generated inputs. When the law fails, it shrinks the input to the smallest one that still fails and reports it with the seed, so the run can be replayed. It is pure Agentica and runs inside `agentica test`.

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  ints = Prop.list(Prop.int(-100, 100))
  result = Prop.check(ints, Prop.Config(seed: some(1234))) do |xs|
    Prop.eq(xs.reverse, xs)
  end

  puts(result.message)
end
```

```output
falsified after 1 run, shrunk to [0,-1], seed 1234: expected [0,-1], got [-1,0]
```

`Prop.check` runs the block on 100 generated lists (`Prop.Config` changes the count), and the block returns a `Result[Void]`: `Prop.eq(actual, expected)` gives `ok()` when the two are equal and an `error` that shows both when they are not. The law "a reversed list is the same list" is false. `check` shrank the first list that broke it to the smallest one it found, `[0,-1]`, and gives the seed that replays the run.

In a test, return the result of `check`. A test is a function whose name starts with `test_`, in a file of `test/` that ends in `_test.agc`:

```agentica
import Prop from "pkg/prop/prop"

def test_reverse_twice() -> Result[Void]
  return Prop.check(Prop.list(Prop.int(-100, 100))) do |xs|
    Prop.eq(xs.reverse.reverse, xs)
  end
end
```

## Install

Needs Agentica 0.31.0-alpha.1 or later. Add it with the prefixed tag of the release, in a project with an `agentica.toml`:

```sh
agentica add prop https://github.com/agentica-lang/packages --tag prop-0.2.1 --subdir prop
```

That writes this line of `agentica.toml`, and the entry of `agentica.lock`:

```toml
[dependencies]
prop = { git = "https://github.com/agentica-lang/packages", tag = "prop-0.2.1", subdir = "prop" }
```

The releases and their notes are in the [changelog](https://github.com/agentica-lang/packages/blob/main/prop/CHANGELOG.md).

## Reference

Everything is under `Prop`, from `import Prop from "pkg/prop/prop"`. Each function has its signature and a short example on its page.

| Page | Functions |
|---|---|
| [Checking](checking.md) | `Prop.check`, `Prop.Config`, `Prop.eq`, `Prop.assume` |
| [Generators](generators.md) | `Prop.int`, `float`, `bool`, `string`, `list`, `optional`, `one_of`, `map`, `pair`, `sample`, `of` |
| [Laws](laws.md) | `Prop.roundtrip`, `idempotent`, `oracle`, `associative`, `commutative`, `preserves` |
| [Exhaustive check](exhaustive.md) | `Prop.exhaustive`, `Prop.cases` |
| [For agents](agents.md) | how an AI that writes Agentica should use the package |
