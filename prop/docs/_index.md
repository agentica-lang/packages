---
title: prop
description: Property-based testing. State a law, check it on many generated inputs, and get the smallest input that breaks it.
---

`prop` checks a law on many generated inputs. When the law fails, it shrinks the input and reports the smallest counterexample with the seed, so you can replay it. It is pure Agentica, with no compiler change, and it runs inside `agentica test` as it is.

## Install

Needs Agentica 0.25.0 or later. Add it with the prefixed tag of the release, in a project with an `agentica.toml`:

```sh
agentica add prop https://github.com/agentica-lang/packages --tag prop-0.1.0 --subdir prop
```

That writes this line of `agentica.toml`, and the entry of `agentica.lock`:

```toml
[dependencies]
prop = { git = "https://github.com/agentica-lang/packages", tag = "prop-0.1.0", subdir = "prop" }
```

The releases and their notes are in the [changelog](https://github.com/agentica-lang/packages/blob/main/prop/CHANGELOG.md).

## Example

Put the laws in `test/`, in a file that ends in `_test.agc`. A test is a function whose name starts with `test_` and that returns `Result[Void]`:

```agentica
import Prop from "pkg/prop/prop"

def test_reverse_twice() -> Result[Void]
  return Prop.check(Prop.list(Prop.int(-100, 100))) do |xs|
    Prop.eq(xs.reverse.reverse, xs)
  end
end
```

`Prop.check` makes 100 lists of Int, runs the block on each one, and returns `ok()` when the law holds for all of them. The block returns a `Result[Void]`. `Prop.eq(actual, expected)` is `ok()` when the two values are equal, and an `error` that shows both when they are not.

A false law fails the test with the shrunk counterexample. This law is false for any list that is not a palindrome:

```agentica
result = Prop.check(Prop.list(Prop.int(-100, 100)), Prop.Config(seed: some(1234))) do |xs|
  Prop.eq(xs.reverse, xs)
end

puts(result.message)
```

```text
falsified after 1 run, shrunk to [0,-1], seed 1234: expected [0,-1], got [-1,0]
```

The first list that broke the law was bigger. `check` shrank it to the smallest one that still breaks it. With the seed, the same run happens again.

## Pages

- [Checking](checking.md): `Prop.check`, the config, seeds, discarding a case, and the rules for a law.
- [Generators](generators.md): the generators, how they shrink, and `Prop.of` for your own types.
- [Laws](laws.md): `roundtrip`, `idempotent`, `oracle`, `associative`, `commutative` and `preserves` in one call each.
- [Exhaustive check](exhaustive.md): every case up to a size, instead of a random sample.
- [For agents](agents.md): how an AI that writes Agentica should use the package.

## API

Everything is under `Prop`, from `import Prop from "pkg/prop/prop"`.

| Name | What it is |
|---|---|
| `Prop.check(gen, config, law)` | runs `law` on the values of `gen`; `config` is optional |
| `Prop.Config(runs: 100, seed: none, discards: 1000, shrinks: 500)` | how a check runs |
| `Prop.eq(actual, expected)` | the equality for a law |
| `Prop.assume(condition)` | discards a case |
| `Prop.int`, `float`, `bool`, `string`, `list`, `optional`, `one_of`, `map`, `pair` | the [generators](generators.md) |
| `Prop.sample(gen, seed, count = 5)` | the values that a seed makes |
| `Prop.of(codec, schema, depth = 2)` | a generator for a struct or an enum |
| `Prop.roundtrip`, `idempotent`, `oracle`, `associative`, `commutative`, `preserves` | the [laws](laws.md) |
| `Prop.exhaustive(gen, size, max_cases = 10_000, law)`, `Prop.cases(gen, size)` | the [exhaustive check](exhaustive.md) |
