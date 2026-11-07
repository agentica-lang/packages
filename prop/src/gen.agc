## Generators. A `Gen[T]` makes the shrink tree of a value from a seed; the same seed gives the same tree.

import Seeds from "seed"
import Trees from "tree"

# `int` and `float` clamp their bounds to this, so a range always fits the 62 bits that `Seeds.draw` can cover.
BOUND = 1152921504606846976
FLOAT_BOUND = 1.0e15
# Letters first, so a string shrinks toward "a"; then printable ASCII, and last the characters that break naive code:
# accents, CJK, an emoji, a tab and a newline.
LETTERS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
SYMBOLS = " _-.,:;!?/\\\"'()[]{}<>@#$%^&*+=|~`é漢🙂\t\n"
ALPHABET = (LETTERS + SYMBOLS).split("")
# The longest list or string; a longer one is not a test of a law, and a lazy list of candidates recurses once
# per item.
MAX_SIZE = 1000

## A source of values of type T for `Prop.check`.
export struct Gen[T]
  make: Fn[Int, Trees.Tree[T]]
end

## Two values, as made by `Prop.pair`.
export struct Pair[A, B]
  first: A
  second: B
end

## An Int in `min` ..= `max` (both clamped to +-2^60) that shrinks toward 0, or toward the bound nearest to 0.
## Halts when `min` is more than `max`.
export def int(min: Int, max: Int) -> Gen[Int]
  if min > max
    bad: Result[Gen[Int]] = error("Prop.int: min #{min} is more than max #{max}")
    return bad.unwrap!
  end

  low = min.clamp(-BOUND, BOUND)
  high = max.clamp(-BOUND, BOUND)
  origin = 0.clamp(low, high)
  return generator() do |seed| Trees.int_tree(low + Seeds.draw(seed, high - low + 1), origin) end
end

## A Float in `min` ..= `max` that shrinks toward 0.0, or toward the bound nearest to it. Halts when `min` is more
## than `max`; the bounds are clamped to +-1e15.
export def float(min: Float, max: Float) -> Gen[Float]
  if min > max
    bad: Result[Gen[Float]] = error("Prop.float: min #{min} is more than max #{max}")
    return bad.unwrap!
  end

  low = min.clamp(-FLOAT_BOUND, FLOAT_BOUND)
  high = max.clamp(-FLOAT_BOUND, FLOAT_BOUND)
  origin = 0.0.clamp(low, high)
  return generator() do |seed| Trees.float_tree(low + Seeds.unit(seed) * (high - low), origin) end
end

## `true` or `false`; `true` shrinks to `false`.
export def bool() -> Gen[Bool]
  return map(int(0, 1)) do |n| n == 1 end
end

## A String of up to `max_size` characters from a mix of ASCII, accented, CJK and emoji ones, a tab and a newline. It
## shrinks to a shorter string, then toward "a".
export def string(max_size: Int = 10) -> Gen[String]
  indexes = list(int(0, ALPHABET.size - 1), max_size)
  return map(indexes) do |chosen| chosen.map do |i| ALPHABET.at(i) end.join("") end
end

## A List of up to `max_size` (at most 1000) items of `gen`. It shrinks to a shorter list (the empty one first), then
## by shrinking an item.
export def list[T](gen: Gen[T], max_size: Int = 10) -> Gen[List[T]]
  limit = max_size.clamp(0, MAX_SIZE)
  return generator() do |seed|
    count = Seeds.draw(Seeds.split(seed, 0), limit + 1)
    trees = (0...count).to_a.map do |i| gen.make(Seeds.split(seed, i + 1)) end
    Trees.list_tree(trees)
  end
end

## `none` or `some` of a value of `gen`, half and half; `some` shrinks to `none` first.
export def optional[T](gen: Gen[T]) -> Gen[Optional[T]]
  return generator() do |seed|
    if Seeds.draw(Seeds.split(seed, 0), 2) == 0
      absent: Trees.Tree[Optional[T]] = Trees.leaf(none)
      return absent
    end

    Trees.some_tree(gen.make(Seeds.split(seed, 1)))
  end
end

## One of `items`, which shrinks toward the first. Halts when `items` is empty.
export def one_of[T](items: List[T]) -> Gen[T]
  if items.empty?
    bad: Result[Gen[T]] = error("Prop.one_of: items is empty")
    return bad.unwrap!
  end

  return map(int(0, items.size - 1)) do |i| items.at(i) end
end

## The values of `gen` through `f`. They shrink as the values of `gen` do.
export def map[A, B](gen: Gen[A], f: Fn[A, B]) -> Gen[B]
  return generator() do |seed| Trees.map_tree(gen.make(seed), f) end
end

## A `Pair` of a value of `a` and one of `b`, shrinking `a` first.
export def pair[A, B](a: Gen[A], b: Gen[B]) -> Gen[Pair[A, B]]
  return generator() do |seed|
    Trees.zip_trees(a.make(Seeds.split(seed, 0)), b.make(Seeds.split(seed, 1))) do |x, y| Pair(first: x, second: y) end
  end
end

## The values that `gen` makes for `count` seeds from `seed` on: the first cases `Prop.check` runs with that seed.
export def sample[T](gen: Gen[T], seed: Int, count: Int = 5) -> List[T]
  return (0...count).to_a.map do |i| gen.make(Seeds.split(seed, i)).value end
end

def generator[T](make: Fn[Int, Trees.Tree[T]]) -> Gen[T]
  return Gen(make: make)
end
