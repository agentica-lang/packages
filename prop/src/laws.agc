## The common laws as one call each: a generator, the functions under test, and an optional `Config` before the last
## function (so the last one can be a block). Each returns what `check` returns. Equality is `Prop.eq`: the values
## are compared as JSON, so two maps with the same pairs in another order differ.

import Checks from "check"
import Gens from "gen"

# Three values for the laws of an operation, named so a counterexample reads `{"a":1,"b":2,"c":3}`.
struct Triple[T]
  a: T
  b: T
  c: T
end

## `decode(encode(x))` is `ok(x)`. `decode` returns a `Result`, as `JSON.decode` does; an `error` falsifies the law.
export def roundtrip[T, E](
  gen: Gens.Gen[T],
  encode: Fn[T, E],
  config: Checks.Config = Checks.Config(),
  decode: Fn[E, Result[T]],
) -> Result[Void]
  return Checks.check(gen, config) do |value| round_trips(value, encode, decode) end
end

## `f(f(x))` is `f(x)`.
export def idempotent[T](gen: Gens.Gen[T], config: Checks.Config = Checks.Config(), f: Fn[T, T]) -> Result[Void]
  return Checks.check(gen, config) do |value| settles(value, f) end
end

## `fast(x)` is `slow(x)`: the fast version against a simple one that is obviously right.
export def oracle[A, B](
  gen: Gens.Gen[A],
  fast: Fn[A, B],
  config: Checks.Config = Checks.Config(),
  slow: Fn[A, B],
) -> Result[Void]
  return Checks.check(gen, config) do |value| agrees(value, fast, slow) end
end

## `op(op(a, b), c)` is `op(a, op(b, c))`.
export def associative[T](gen: Gens.Gen[T], config: Checks.Config = Checks.Config(), op: Fn[T, T, T]) -> Result[Void]
  triples = Gens.map(Gens.pair(gen, Gens.pair(gen, gen))) do |p| triple(p) end
  return Checks.check(triples, config) do |t| groups_the_same(t, op) end
end

## `op(a, b)` is `op(b, a)`.
export def commutative[T](gen: Gens.Gen[T], config: Checks.Config = Checks.Config(), op: Fn[T, T, T]) -> Result[Void]
  return Checks.check(Gens.pair(gen, gen), config) do |p| orders_the_same(p, op) end
end

## `measure(f(x))` is `measure(x)`: `f` keeps the size, the sum, the sortedness or whatever `measure` reads.
export def preserves[T, M](
  gen: Gens.Gen[T],
  f: Fn[T, T],
  config: Checks.Config = Checks.Config(),
  measure: Fn[T, M],
) -> Result[Void]
  return Checks.check(gen, config) do |value| keeps(value, f, measure) end
end

def round_trips[T, E](value: T, encode: Fn[T, E], decode: Fn[E, Result[T]]) -> Result[Void]
  back = decode.call(encode.call(value))
  if not back.ok?
    return error("decode(encode(x)) failed: #{back.message}")
  end

  return labelled("decode(encode(x)) differs from x", Checks.eq(back.unwrap!, value))
end

def settles[T](value: T, f: Fn[T, T]) -> Result[Void]
  return labelled("f(f(x)) differs from f(x)", Checks.eq(f.call(f.call(value)), f.call(value)))
end

def agrees[A, B](value: A, fast: Fn[A, B], slow: Fn[A, B]) -> Result[Void]
  return labelled("fast(x) differs from slow(x)", Checks.eq(fast.call(value), slow.call(value)))
end

def triple[T](p: Gens.Pair[T, Gens.Pair[T, T]]) -> Triple[T]
  return Triple(a: p.first, b: p.second.first, c: p.second.second)
end

def groups_the_same[T](t: Triple[T], op: Fn[T, T, T]) -> Result[Void]
  left = op.call(op.call(t.a, t.b), t.c)
  right = op.call(t.a, op.call(t.b, t.c))
  return labelled("op(op(a, b), c) differs from op(a, op(b, c))", Checks.eq(left, right))
end

def orders_the_same[T](p: Gens.Pair[T, T], op: Fn[T, T, T]) -> Result[Void]
  return labelled("op(a, b) differs from op(b, a)", Checks.eq(op.call(p.first, p.second), op.call(p.second, p.first)))
end

def keeps[T, M](value: T, f: Fn[T, T], measure: Fn[T, M]) -> Result[Void]
  return labelled("measure(f(x)) differs from measure(x)", Checks.eq(measure.call(f.call(value)), measure.call(value)))
end

# The reason first, then what `Prop.eq` saw: `fast(x) differs from slow(x): expected 3, got 4`.
def labelled(reason: String, verdict: Result[Void]) -> Result[Void]
  if verdict.ok?
    return verdict
  end

  return error("#{reason}: #{verdict.message}")
end
