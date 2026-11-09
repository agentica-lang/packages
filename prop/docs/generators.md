---
title: Generators
description: The generators, how a value shrinks, and Prop.of for your own structs and enums.
weight: 2
---

A `Gen[T]` makes values of type `T` from a seed. It also makes a shrink tree: the value and, on demand, its simpler values. That is why `map` and `pair` shrink with no inverse function.

## The generators

| Generator | Makes | Shrinks |
|---|---|---|
| `Prop.int(min, max)` | an Int in the range | toward 0, or the bound nearest to it |
| `Prop.float(min, max)` | a Float in the range | toward 0.0, or the bound nearest to it |
| `Prop.bool()` | `true` or `false` | to `false` |
| `Prop.string(max_size = 10)` | a string of up to `max_size` characters (ASCII, accented, CJK and emoji ones, a tab and a newline) | to a shorter string, then toward `"a"` |
| `Prop.list(gen, max_size = 10)` | a list of up to `max_size` items | to fewer items (the empty list first), then to smaller items |
| `Prop.optional(gen)` | `none` or `some` (half each) | `some` to `none` |
| `Prop.one_of(items)` | one item of the list | toward the first |
| `Prop.pair(a, b)` | a `Prop.Pair(first, second)` | each part |
| `Prop.map(gen, f)` | the values of `gen` through `f` | as the originals do |

`max_size` is at most 1000.

```agentica {mode="fragment"}
ages = Prop.int(0, 120)
names = Prop.one_of(["ana", "ben", "cat"])
people = Prop.pair(names, ages)
tens = Prop.map(Prop.int(1, 5)) do |n| n * 10 end
```

`Prop.sample(gen, seed, count = 5)` returns the first values that `check` would try with that seed. It is a good way to see what a generator makes:

```agentica {mode="fragment"}
puts(Prop.sample(Prop.pair(Prop.int(0, 9), Prop.string(3)), 5, 2))
puts(Prop.sample(Prop.optional(Prop.int(0, 3)), 1, 6))
```

```text
[Pair(first: 6, second: "R_f"), Pair(first: 6, second: "")]
[none, none, none, none, some(3), some(0)]
```

## Generators for your types

`Prop.of(codec, schema, depth = 2)` makes values of a struct or an enum that JSON can decode. Pass the codec and the JSON Schema of the same type:

```agentica
import Prop from "pkg/prop/prop"

struct User
  name: String
  age: Int
  email: Optional[String]
end

def encode_user(user: User) -> String
  return User.codec.encode(user)
end

def decode_user(text: String) -> Result[User]
  return User.codec.decode(text)
end

def test_user_round_trip() -> Result[Void]
  gen = Prop.of(User.codec, JSON.schema(User))
  return Prop.roundtrip(gen, &encode_user, &decode_user)
end
```

Agentica cannot read a type from a codec, so the schema is passed as well. The generator makes the JSON that the schema allows, and the codec decodes it, so a value is always one that `User` can have. A schema of another type than the codec's halts the test with the decode error.

What it makes:

- Int is in -1000 to 1000, Float in -1000.0 to 1000.0, strings as `Prop.string()`, and lists have up to 3 items.
- A map has up to 3 pairs with random keys (up to 4 characters, the empty one too).
- Every field is made. An `Optional` is `none` half of the time, and an enum picks a variant.
- A key that is missing from the JSON is never made. An `Optional` or defaulted field is always present (with `null` for `none`). Test that input in a plain `test_`, with `User.codec.decode` of a text without the key.
- Shrinking goes through the parts: an `Optional` to `none`, a list to fewer items, a variant to an earlier one, a number toward 0.
- A type that holds itself (through a list, a map, an `Optional` or a variant) nests at most `depth` times, then the list, map, `Optional` or variant that ends it is chosen. A type that cannot end (a required field of its own type) halts.

A case of a big struct is expensive: one with six fields, a nested struct and an enum takes about 5000 steps, before the law runs. With the step budget of a test (see [Checking](checking.md)), keep `depth` small and `runs` at a few hundred.
