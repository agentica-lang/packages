---
title: Generators
description: The generators, each with an example of what it makes, then how values shrink and Prop.of for your own types.
weight: 2
---

A generator, `Gen[T]`, makes values of type `T` from a seed. The examples show what a generator makes with `Prop.sample`, the first values that `Prop.check` would try with that seed.

The types are `Prop.Gen[T]` and `Prop.Pair[A, B]`. To write them bare in the signature of a helper, import the names next to the module: `import {Gen, Pair} from "pkg/prop/prop"` (on its own line, after `import Prop from "pkg/prop/prop"`).

```agentica
import Prop from "pkg/prop/prop"
import {Gen, Pair} from "pkg/prop/prop"

def tagged(gen: Gen[String]) -> Gen[Pair[Int, String]] = Prop.pair(Prop.int(0, 9), gen)

def main() -> Void
  puts(Prop.sample(tagged(Prop.one_of(["a", "b"])), 1, 2))
end
```

```output
[Pair(first: 4, second: "b"), Pair(first: 4, second: "a")]
```

## Prop.sample

```signature
Prop.sample(gen: Gen[T], seed: Int, count: Int = 5) -> List[T]
```

The values that `gen` makes for `count` seeds from `seed` on: the first cases that `Prop.check` runs with that seed.

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  puts(Prop.sample(Prop.int(0, 9), 1234))
end
```

```output
[6, 6, 0, 4, 2]
```

## Prop.int

```signature
Prop.int(min: Int, max: Int) -> Gen[Int]
```

An Int in `min` to `max`, both included, with both bounds clamped to -2^60 and 2^60. It shrinks toward 0, or toward the bound nearest to 0. A `min` above `max` halts the test.

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  puts(Prop.sample(Prop.int(-5, 5), 1))
end
```

```output
[2, -1, -3, 3, 4]
```

## Prop.float

```signature
Prop.float(min: Float, max: Float) -> Gen[Float]
```

A Float in `min` to `max`, with both bounds clamped to -1e15 and 1e15. It shrinks toward 0.0, or toward the bound nearest to it.

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  puts(Prop.sample(Prop.float(0.0, 1.0), 1, 3))
end
```

```output
[0.5514195375144482, 0.4739080984145403, 0.2005640072748065]
```

## Prop.bool

```signature
Prop.bool() -> Gen[Bool]
```

`true` or `false`. `true` shrinks to `false`.

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  puts(Prop.sample(Prop.bool(), 1))
end
```

```output
[false, false, false, true, true]
```

## Prop.string

```signature
Prop.string(max_size: Int = 10) -> Gen[String]
```

A String of up to `max_size` characters: ASCII, accented, CJK and emoji ones, a tab and a newline. It shrinks to a shorter string, then toward `"a"`.

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  puts(Prop.sample(Prop.string(4), 3))
end
```

```output
[".", "", "L", "", "R"]
```

## Prop.list

```signature
Prop.list(gen: Gen[T], max_size: Int = 10) -> Gen[List[T]]
```

A List of up to `max_size` items of `gen` (`max_size` is at most 1000). It shrinks to fewer items, the empty list first, then to smaller items.

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  puts(Prop.sample(Prop.list(Prop.int(0, 9), 3), 2, 3))
end
```

```output
[[4, 1, 6], [4, 0], [3, 8, 9]]
```

## Prop.non_empty_list

```signature
Prop.non_empty_list(gen: Gen[T], max_size: Int = 10) -> Gen[List[T]]
```

A List of 1 up to `max_size` items of `gen` (`max_size` is at most 1000, and a `max_size` below 1 halts the test). It shrinks to a one-item list, then to smaller items, and never to the empty list. Use it where an empty list is no input.

It is also the generator of a cut: the sizes of the pieces that a sequence is split into, none of them 0, so a law can check every way to cut a parser's input. `Prop.non_empty_list(Prop.int(1, 12))` gives sizes to cycle through until the input is used up.

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  puts(Prop.sample(Prop.non_empty_list(Prop.int(1, 9), 3), 2, 3))
end
```

```output
[[7, 1, 1], [3], [8, 3]]
```

```agentica
import Prop from "pkg/prop/prop"

def cut(whole: Bytes, sizes: List[Int]) -> List[Bytes]
  pieces: List[Bytes] = []
  rest = whole
  turn = 0
  while not rest.empty?
    size = sizes.at(turn % sizes.size)
    pieces = pieces.push(rest.take(size))
    rest = rest.drop(size)
    turn += 1
  end

  pieces
end

def main() -> Void
  cuts = Prop.pair(Prop.bytes(0, 40), Prop.non_empty_list(Prop.int(1, 12)))
  result = Prop.check(cuts) do |p|
    Prop.eq(Bytes.concat(cut(p.first, p.second)).to_a, p.first.to_a)
  end

  puts(result)
end
```

```output
ok()
```

## Prop.bytes

```signature
Prop.bytes(min: Int = 0, max: Int = 16) -> Gen[Bytes]
```

Bytes of `min` up to `max` values from 0 to 255. Both are at most 1000, and a `min` below 0 or above `max` halts the test. They shrink to fewer bytes, down to `min`, and each byte toward 0.

`Bytes` is not JSON, so `Prop.eq` cannot compare it (`CHECK-NOT-ENCODABLE`): compare `bytes.to_a`, or use `==` in a law that fails with `error(...)`. A counterexample of bytes is written as the list of their values. The [laws](laws.md) work with it: `Prop.roundtrip(Prop.bytes(), &encode, &decode)` compares the bytes as the text of the generator. Only the results of `Prop.oracle` and `Prop.preserves` go through `Prop.eq`, so return `bytes.to_a` from them.

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  puts(Prop.sample(Prop.bytes(1, 3), 1, 2).map do |bytes| bytes.to_a end)
  result = Prop.check(Prop.bytes(2, 12), Prop.Config(seed: some(3))) do |bytes|
    Prop.eq(bytes.length < 4, true)
  end

  puts(result.message)
end
```

```output
[[5, 191], [248]]
falsified after 2 runs, shrunk to [0,0,0,0], seed 3: expected true, got false
```

## Prop.optional

```signature
Prop.optional(gen: Gen[T]) -> Gen[Optional[T]]
```

`none` or `some` of a value of `gen`, half and half. `some` shrinks to `none` first.

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  puts(Prop.sample(Prop.optional(Prop.int(0, 3)), 1, 6))
end
```

```output
[none, none, none, none, some(3), some(0)]
```

## Prop.one_of

```signature
Prop.one_of(items: List[T]) -> Gen[T]
```

One of `items`. It shrinks toward the first item, so put the simplest first. An empty list halts the test. The items go to `JSON.encode`, so they cannot be `Bytes`: for fixed test vectors, draw the index and show the value with [`Prop.map_shown`](#propmap_shown), as `Prop.map_shown(Prop.int(0, vectors.size - 1), &show) do |i| vectors.at(i) end`.

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  puts(Prop.sample(Prop.one_of(["ana", "ben", "cat"]), 1))
end
```

```output
["cat", "ana", "ana", "ana", "cat"]
```

## Prop.map

```signature
Prop.map(gen: Gen[A], f: Fn[A, B]) -> Gen[B]
```

The values of `gen` through `f`. They shrink as the values of `gen` do, with no inverse function.

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  tens = Prop.map(Prop.int(1, 5)) do |n| n * 10 end
  puts(Prop.sample(tens, 1))
end
```

```output
[30, 20, 50, 40, 10]
```

## Prop.map_shown

```signature
Prop.map_shown(gen: Gen[A], show: Fn[B, String], f: Fn[A, B]) -> Gen[B]
```

`Prop.map` for a result that JSON cannot encode, such as a struct with a `Bytes` field: `show` writes a value for the counterexample. A generator of `Bytes` or of a struct with bytes needs it, as `Prop.map` (and `Prop.one_of`) give each value to `JSON.encode`.

```agentica
import Prop from "pkg/prop/prop"

struct Frame
  tag: Int
  data: Bytes
end

def label(frame: Frame) -> String = "#{frame.tag}:#{frame.data.to_a}"

def main() -> Void
  parts = Prop.pair(Prop.int(0, 9), Prop.bytes(0, 6))
  frames = Prop.map_shown(parts, &label) do |p| Frame(tag: p.first, data: p.second) end
  result = Prop.check(frames, Prop.Config(seed: some(5))) do |frame|
    return error("three bytes or more") if frame.data.length >= 3

    ok()
  end

  puts(result.message)
end
```

```output
falsified after 1 run, shrunk to 0:[0, 0, 0], seed 5: three bytes or more
```

## Prop.pair

```signature
Prop.pair(a: Gen[A], b: Gen[B]) -> Gen[Pair[A, B]]
```

A `Prop.Pair(first, second)` of a value of `a` and one of `b`. It shrinks `first`, then `second`.

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  puts(Prop.sample(Prop.pair(Prop.int(0, 9), Prop.bool()), 5, 2))
end
```

```output
[Pair(first: 6, second: true), Pair(first: 6, second: false)]
```

## Prop.of

```signature
Prop.of(codec: Codec[T], schema: JSON.Value, depth: Int = 2) -> Gen[T]
```

Values of a struct or an enum that JSON can decode. Pass `T.codec` and `JSON.schema(T)` of the same type: the generator makes the JSON that the schema allows, and the codec decodes it.

```agentica
import Prop from "pkg/prop/prop"

struct User
  name: String
  age: Int
end

def main() -> Void
  users = Prop.of(User.codec, JSON.schema(User))
  puts(Prop.sample(users, 1, 2))
end
```

```output
[User(name: "mdRY", age: 423), User(name: "TeL%;yAb+", age: -973)]
```

## Shrinking

A generator makes a shrink tree: a value and, on demand, its simpler values. When a law fails, `check` walks that tree to the simplest value that still fails. That is why `map` and `pair` shrink with no inverse function.

```agentica
import Prop from "pkg/prop/prop"

def main() -> Void
  config = Prop.Config(seed: some(3))
  result = Prop.check(Prop.list(Prop.int(0, 100)), config) do |xs|
    Prop.eq(xs.all? do |x| x <= 40 end, true)
  end

  puts(result.message)
end
```

```output
falsified after 1 run, shrunk to [41], seed 3: expected true, got false
```

The shrunk list has one item, at the smallest value that still breaks the law.

## More on Prop.of

The usual law for a type with a codec is the round trip: encode a value, decode the text, and get the same value back.

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

Agentica cannot read a type from a codec, so the schema is passed too. A schema of another type than the codec's halts the test with the decode error. What `Prop.of` makes:

- Int is in -1000 to 1000, Float in -1000.0 to 1000.0, strings as `Prop.string()`, and lists have up to 3 items.
- A map has up to 3 pairs with random keys (up to 4 characters, the empty one too).
- Every field is made. An `Optional` is `none` half of the time, and an enum picks a variant.
- A key that is missing from the JSON is never made. An `Optional` or defaulted field is always present (with `null` for `none`). Test that input in a plain `test_`, with `User.codec.decode` of a text without the key.
- Shrinking goes through the parts: an `Optional` to `none`, a list to fewer items, a variant to an earlier one, a number toward 0.
- A type that holds itself (through a list, a map, an `Optional` or a variant) nests at most `depth` times, then the list, map, `Optional` or variant that ends it is chosen. A type that cannot end (a required field of its own type) halts.

A case of a big struct is expensive: one with six fields, a nested struct and an enum takes about 5000 steps, before the law runs. With the step budget of a test (see [Checking](checking.md)), keep `depth` small and `runs` at a few hundred.
