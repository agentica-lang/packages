## The common laws as one call each: a generator, the functions under test, and an optional `Config` before the last
## function (so the last one can be a block). Each returns what `check` returns. Equality is `Prop.eq`: the values
## are compared as JSON, so two maps with the same pairs in another order differ.

import Checks from "check"
import Gens from "gen"

## `decode(encode(x))` is `ok(x)`. `decode` returns a `Result`, as `JSON.decode` does; an `error` falsifies the law.
##
## ```ruby
## def show(n: Int) -> String
##   return n.to_s
## end
##
## Prop.roundtrip(Prop.int(-1000, 1000), &show) do |text| text.to_i end # ok()
## ```
def roundtrip[T, E](
  gen: Gens.Gen[T],
  encode: Fn[T, E],
  config: Checks.Config = Checks.Config(),
  decode: Fn[E, Result[T]],
) -> Result[Void]
  Checks.check(gen, config) do |value| round_trips(value, encode, decode, gen.show) end
end

## `f(f(x))` is `f(x)`.
##
## ```ruby
## Prop.idempotent(Prop.list(Prop.int(-9, 9))) do |xs| xs.sort end # ok()
## ```
def idempotent[T](gen: Gens.Gen[T], config: Checks.Config = Checks.Config(), f: Fn[T, T]) -> Result[Void]
  Checks.check(gen, config) do |value| settles(value, f, gen.show) end
end

## `fast(x)` is `slow(x)`: the fast version against a simple one that is obviously right.
##
## ```ruby
## def fast_sum(xs: List[Int]) -> Int
##   return xs.sum
## end
##
## Prop.oracle(Prop.list(Prop.int(-9, 9)), &fast_sum) do |xs| xs.reduce(0) do |sum, x| sum + x end end # ok()
## ```
def oracle[A, B](
  gen: Gens.Gen[A],
  fast: Fn[A, B],
  config: Checks.Config = Checks.Config(),
  slow: Fn[A, B],
) -> Result[Void]
  Checks.check(gen, config) do |value| agrees(value, fast, slow) end
end

## `op(op(a, b), c)` is `op(a, op(b, c))`.
##
## ```ruby
## Prop.associative(Prop.string(3)) do |a, b| a + b end # ok()
## ```
def associative[T](gen: Gens.Gen[T], config: Checks.Config = Checks.Config(), op: Fn[T, T, T]) -> Result[Void]
  triples = Gens.map_shown(Gens.pair(gen, Gens.pair(gen, gen)), triple_text(gen.show)) do |p| triple(p) end
  Checks.check(triples, config) do |t| groups_the_same(t, op, gen.show) end
end

## `op(a, b)` is `op(b, a)`.
##
## ```ruby
## Prop.commutative(Prop.int(-9, 9)) do |a, b| a * b end # ok()
## ```
def commutative[T](gen: Gens.Gen[T], config: Checks.Config = Checks.Config(), op: Fn[T, T, T]) -> Result[Void]
  couples = Gens.map_shown(Gens.pair(gen, gen), couple_text(gen.show)) do |p| Couple(a: p.first, b: p.second) end
  Checks.check(couples, config) do |c| orders_the_same(c, op, gen.show) end
end

## `measure(f(x))` is `measure(x)`: `f` keeps the size, the sum, the sortedness or whatever `measure` reads.
##
## ```ruby
## def reverse(xs: List[Int]) -> List[Int]
##   return xs.reverse
## end
##
## Prop.preserves(Prop.list(Prop.int(-9, 9)), &reverse) do |xs| xs.sum end # ok(): a reverse keeps the sum
## ```
def preserves[T, M](
  gen: Gens.Gen[T],
  f: Fn[T, T],
  config: Checks.Config = Checks.Config(),
  measure: Fn[T, M],
) -> Result[Void]
  Checks.check(gen, config) do |value| keeps(value, f, measure) end
end

private

# Two values for the law of an operation, named like the first two of a `Triple`.
struct Couple[T]
  a: T
  b: T
end

# Three values for the laws of an operation, named so a counterexample reads `{"a":1,"b":2,"c":3}`.
struct Triple[T]
  a: T
  b: T
  c: T
end

def round_trips[T, E](value: T, encode: Fn[T, E], decode: Fn[E, Result[T]], show: Fn[T, String]) -> Result[Void]
  back = decode.call(encode.call(value))
  return error("decode(encode(x)) failed: #{back.message}") if not back.ok?

  labelled("decode(encode(x)) differs from x", Checks.eq_shown(back.unwrap!, value, show))
end

def settles[T](value: T, f: Fn[T, T], show: Fn[T, String]) -> Result[Void]
  labelled("f(f(x)) differs from f(x)", Checks.eq_shown(f.call(f.call(value)), f.call(value), show))
end

def agrees[A, B](value: A, fast: Fn[A, B], slow: Fn[A, B]) -> Result[Void]
  labelled("fast(x) differs from slow(x)", Checks.eq(fast.call(value), slow.call(value)))
end

# The text of a `Triple` and a `Couple` for a counterexample, from the `show` of their items: the JSON of the struct.
def triple_text[T](show: Fn[T, String]) -> Fn[Triple[T], String]
  ->(t: Triple[T]) { "{\"a\":#{show.call(t.a)},\"b\":#{show.call(t.b)},\"c\":#{show.call(t.c)}}" }
end

def couple_text[T](show: Fn[T, String]) -> Fn[Couple[T], String]
  ->(c: Couple[T]) { "{\"a\":#{show.call(c.a)},\"b\":#{show.call(c.b)}}" }
end

def triple[T](p: Gens.Pair[T, Gens.Pair[T, T]]) -> Triple[T]
  Triple(a: p.first, b: p.second.first, c: p.second.second)
end

def groups_the_same[T](t: Triple[T], op: Fn[T, T, T], show: Fn[T, String]) -> Result[Void]
  left = op.call(op.call(t.a, t.b), t.c)
  right = op.call(t.a, op.call(t.b, t.c))
  labelled("op(op(a, b), c) differs from op(a, op(b, c))", Checks.eq_shown(left, right, show))
end

def orders_the_same[T](c: Couple[T], op: Fn[T, T, T], show: Fn[T, String]) -> Result[Void]
  labelled("op(a, b) differs from op(b, a)", Checks.eq_shown(op.call(c.a, c.b), op.call(c.b, c.a), show))
end

def keeps[T, M](value: T, f: Fn[T, T], measure: Fn[T, M]) -> Result[Void]
  labelled("measure(f(x)) differs from measure(x)", Checks.eq(measure.call(f.call(value)), measure.call(value)))
end

# The reason first, then what `Prop.eq` saw: `fast(x) differs from slow(x): expected 3, got 4`.
def labelled(reason: String, verdict: Result[Void]) -> Result[Void]
  return verdict if verdict.ok?

  error("#{reason}: #{verdict.message}")
end
