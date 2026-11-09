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
# A count of cases stops growing here, so a product of counts never overflows an Int.
CAP = 1_000_000_000

## A source of values of type T for `Prop.check` and `Prop.exhaustive`. `make` draws a shrink tree from a seed;
## `count` and `all` are the small cases for a size: how many there are (a count stops at 1_000_000_000) and the
## values, simplest first.
export struct Gen[T]
  make: Fn[Int, Trees.Tree[T]]
  count: Fn[Int, Int]
  all: Fn[Int, List[T]]
end

## Two values, as made by `Prop.pair`.
export struct Pair[A, B]
  first: A
  second: B
end

## An Int in `min` ..= `max` (both clamped to +-2^60) that shrinks toward 0, or toward the bound nearest to 0.
## Halts when `min` is more than `max`. At size k it has the Ints up to k away from that origin.
##
## ```ruby
## Prop.sample(Prop.int(-5, 5), 1) # [2, -1, -3, 3, 4]
## ```
export def int(min: Int, max: Int) -> Gen[Int]
  if min > max
    bad: Result[Gen[Int]] = error("Prop.int: min #{min} is more than max #{max}")
    return bad.unwrap!
  end

  low = min.clamp(-BOUND, BOUND)
  high = max.clamp(-BOUND, BOUND)
  origin = 0.clamp(low, high)
  return Gen(
    make: making() do |seed| Trees.int_tree(low + Seeds.draw(seed, high - low + 1), origin) end,
    count: counting() do |size| reach(high - origin, origin - low, size) end,
    all: listing() do |size| offsets(high - origin, origin - low, size).map do |step| origin + step end end,
  )
end

## A Float in `min` ..= `max` that shrinks toward 0.0, or toward the bound nearest to it. Halts when `min` is more
## than `max`; the bounds are clamped to +-1e15. At size k it has the whole numbers up to k away from that origin.
##
## ```ruby
## Prop.sample(Prop.float(0.0, 1.0), 1, 2) # [0.5514195375144482, 0.4739080984145403]
## ```
export def float(min: Float, max: Float) -> Gen[Float]
  if min > max
    bad: Result[Gen[Float]] = error("Prop.float: min #{min} is more than max #{max}")
    return bad.unwrap!
  end

  low = min.clamp(-FLOAT_BOUND, FLOAT_BOUND)
  high = max.clamp(-FLOAT_BOUND, FLOAT_BOUND)
  origin = 0.0.clamp(low, high)
  up = (high - origin).floor
  down = (origin - low).floor
  return Gen(
    make: making() do |seed| Trees.float_tree(low + Seeds.unit(seed) * (high - low), origin) end,
    count: counting() do |size| reach(up, down, size) end,
    all: listing() do |size| offsets(up, down, size).map do |step| origin + step.to_f end end,
  )
end

## `true` or `false`; `true` shrinks to `false`.
##
## ```ruby
## Prop.sample(Prop.bool(), 1) # [false, false, false, true, true]
## ```
export def bool() -> Gen[Bool]
  return one_of([false, true])
end

## A String of up to `max_size` characters from a mix of ASCII, accented, CJK and emoji ones, a tab and a newline. It
## shrinks to a shorter string, then toward "a". At size k it has the strings of up to k characters from the first
## k + 1 letters.
##
## ```ruby
## Prop.sample(Prop.string(4), 3) # [".", "", "L", "", "R"]
## ```
export def string(max_size: Int = 10) -> Gen[String]
  indexes = list(int(0, ALPHABET.size - 1), max_size)
  return map(indexes) do |chosen| chosen.map do |i| ALPHABET.at(i) end.join("") end
end

## A List of up to `max_size` (at most 1000) items of `gen`. It shrinks to a shorter list (the empty one first), then
## by shrinking an item. At size k it has the lists of up to k items, each an item of `gen` at size k.
##
## ```ruby
## Prop.sample(Prop.list(Prop.int(0, 9), 3), 2, 3) # [[4, 1, 6], [4, 0], [3, 8, 9]]
## ```
export def list[T](gen: Gen[T], max_size: Int = 10) -> Gen[List[T]]
  limit = max_size.clamp(0, MAX_SIZE)
  return Gen(
    make: making() do |seed|
      count = Seeds.draw(Seeds.split(seed, 0), limit + 1)
      trees = (0...count).to_a.map do |i| gen.make(Seeds.split(seed, i + 1)) end
      Trees.list_tree(trees)
    end,
    count: counting() do |size| lists_count(gen.count(size), size.clamp(0, limit)) end,
    all: listing() do |size| lists_up_to(gen.all(size), size.clamp(0, limit)) end,
  )
end

## `none` or `some` of a value of `gen`, half and half; `some` shrinks to `none` first.
##
## ```ruby
## Prop.sample(Prop.optional(Prop.int(0, 3)), 1, 6) # [none, none, none, none, some(3), some(0)]
## ```
export def optional[T](gen: Gen[T]) -> Gen[Optional[T]]
  return Gen(
    make: making() do |seed|
      if Seeds.draw(Seeds.split(seed, 0), 2) == 0
        absent: Trees.Tree[Optional[T]] = Trees.leaf(none)
        return absent
      end

      Trees.some_tree(gen.make(Seeds.split(seed, 1)))
    end,
    count: counting() do |size| saturate(1 + gen.count(size)) end,
    all: listing() do |size|
      absent: List[Optional[T]] = [none]
      absent.concat(gen.all(size).map do |value| some(value) end)
    end,
  )
end

## One of `items`, which shrinks toward the first. Halts when `items` is empty. Every size has all the items.
##
## ```ruby
## Prop.sample(Prop.one_of(["ana", "ben", "cat"]), 1) # ["cat", "ana", "ana", "ana", "cat"]
## ```
export def one_of[T](items: List[T]) -> Gen[T]
  if items.empty?
    bad: Result[Gen[T]] = error("Prop.one_of: items is empty")
    return bad.unwrap!
  end

  chosen = map(int(0, items.size - 1)) do |i| items.at(i) end
  return Gen(make: chosen.make, count: counting() do |_| items.size end, all: listing() do |_| items end)
end

## The values of `gen` through `f`. They shrink as the values of `gen` do.
##
## ```ruby
## Prop.sample(Prop.map(Prop.int(1, 5)) do |n| n * 10 end, 1) # [30, 20, 50, 40, 10]
## ```
export def map[A, B](gen: Gen[A], f: Fn[A, B]) -> Gen[B]
  return Gen(
    make: making() do |seed| Trees.map_tree(gen.make(seed), f) end,
    count: gen.count,
    all: listing() do |size| gen.all(size).map do |value| f.call(value) end end,
  )
end

## A `Pair` of a value of `a` and one of `b`, shrinking `a` first.
##
## ```ruby
## Prop.sample(Prop.pair(Prop.int(0, 9), Prop.bool()), 5, 2)
## # [Pair(first: 6, second: true), Pair(first: 6, second: false)]
## ```
export def pair[A, B](a: Gen[A], b: Gen[B]) -> Gen[Pair[A, B]]
  return Gen(
    make: making() do |seed|
      Trees.zip_trees(a.make(Seeds.split(seed, 0)), b.make(Seeds.split(seed, 1))) do |x, y|
        Pair(first: x, second: y)
      end
    end,
    count: counting() do |size| saturate(a.count(size) * b.count(size)) end,
    all: listing() do |size| pairs(a.all(size), b.all(size)) end,
  )
end

## The values that `gen` makes for `count` seeds from `seed` on: the first cases `Prop.check` runs with that seed.
##
## ```ruby
## Prop.sample(Prop.int(0, 9), 1234) # [6, 6, 0, 4, 2]
## ```
export def sample[T](gen: Gen[T], seed: Int, count: Int = 5) -> List[T]
  return (0...count).to_a.map do |i| gen.make(Seeds.split(seed, i)).value end
end

## Whether a count stopped growing at its cap, so it is a lower bound.
export def capped?(count: Int) -> Bool
  return count >= CAP
end

## `value`, always.
export def just[T](value: T) -> Gen[T]
  return Gen(
    make: making() do |_| Trees.leaf(value) end,
    count: counting() do |_| 1 end,
    all: listing() do |_| [value] end,
  )
end

## One value of each of `gens`, in order: a list as long as `gens`, which shrinks only through its items.
export def sequence[T](gens: List[Gen[T]]) -> Gen[List[T]]
  return Gen(
    make: making() do |seed|
      Trees.fixed_tree((0...gens.size).to_a.map do |i| gens.at(i).make(Seeds.split(seed, i)) end)
    end,
    count: counting() do |size| gens.reduce(1) do |total, gen| saturate(total * gen.count(size)) end end,
    all: listing() do |size| product(gens.map do |gen| gen.all(size) end) end,
  )
end

## A value of one of `gens` (halts when there is none). It shrinks to the earlier gens first: put the simplest first.
export def choose[T](gens: List[Gen[T]]) -> Gen[T]
  if gens.empty?
    bad: Result[Gen[T]] = error("Prop.choose: gens is empty")
    return bad.unwrap!
  end

  return Gen(
    make: making() do |seed|
      index = Seeds.draw(Seeds.split(seed, 0), gens.size)
      Trees.choice_tree(index) do |i| gens.at(i).make(Seeds.split(seed, i + 1)) end
    end,
    count: counting() do |size| gens.reduce(0) do |total, gen| saturate(total + gen.count(size)) end end,
    all: listing() do |size| gens.reduce([]) do |all, gen| all.concat(gen.all(size)) end end,
  )
end

# The three functions of a `Gen` are blocks: these hand a block back as the `Fn` value a field holds.
def making[T](make: Fn[Int, Trees.Tree[T]]) -> Fn[Int, Trees.Tree[T]]
  return make
end

def counting(count: Fn[Int, Int]) -> Fn[Int, Int]
  return count
end

def listing[T](all: Fn[Int, List[T]]) -> Fn[Int, List[T]]
  return all
end

def saturate(n: Int) -> Int
  return n.clamp(0, CAP)
end

# How many values lie up to `size` away from the origin, with `up` of room above it and `down` below.
def reach(up: Int, down: Int, size: Int) -> Int
  return saturate(1 + saturate(size.clamp(0, up)) + saturate(size.clamp(0, down)))
end

# The distances from the origin, simplest first: 0, 1, -1, 2, -2, ...
def offsets(up: Int, down: Int, size: Int) -> List[Int]
  out = [0]
  step = 1
  while step <= size and (step <= up or step <= down)
    if step <= up
      out = out.push(step)
    end

    if step <= down
      out = out.push(0 - step)
    end

    step += 1
  end

  return out
end

# 1 + n + n^2 + ... + n^longest, stopping at CAP.
def lists_count(items: Int, longest: Int) -> Int
  total = 0
  power = 1
  length = 0
  while length <= longest and total < CAP
    total = saturate(total + power)
    power = saturate(power * items)
    length += 1
  end

  return total
end

# The lists of 0 up to `longest` items, the shorter first.
def lists_up_to[T](items: List[T], longest: Int) -> List[List[T]]
  out: List[List[T]] = []
  for length in 0..longest
    out = out.concat(sequences(items, length))
  end

  return out
end

def sequences[T](items: List[T], length: Int) -> List[List[T]]
  out: List[List[T]] = []
  if length == 0
    return out.push([])
  end

  tails = sequences(items, length - 1)
  for item in items
    for tail in tails
      out = out.push([item].concat(tail))
    end
  end

  return out
end

def pairs[A, B](as: List[A], bs: List[B]) -> List[Pair[A, B]]
  out: List[Pair[A, B]] = []
  for a in as
    for b in bs
      out = out.push(Pair(first: a, second: b))
    end
  end

  return out
end

# Every list with one item from each of `choices`, the first list changing slowest.
def product[T](choices: List[List[T]]) -> List[List[T]]
  out: List[List[T]] = []
  out = out.push([])
  for options in choices
    next_out: List[List[T]] = []
    for prefix in out
      for option in options
        next_out = next_out.push(prefix.push(option))
      end
    end

    out = next_out
  end

  return out
end
