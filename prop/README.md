# prop

Property-based testing for Agentica: state a law, check it on many generated inputs, and get the smallest input that
breaks it. Pure Agentica, no compiler change; it runs in `agentica test` as it is. Add it in a project with an
`agentica.toml`:

```sh
agentica add prop https://github.com/agentica-lang/packages --tag prop-0.1.0 --subdir prop
```

That writes this line of `agentica.toml`, and the entry of `agentica.lock`:

```toml
[dependencies]
prop = { git = "https://github.com/agentica-lang/packages", tag = "prop-0.1.0", subdir = "prop" }
```

```ruby
import Prop from "pkg/prop/prop"

def test_reverse_twice() -> Result[Void]
  return Prop.check(Prop.list(Prop.int(-100, 100))) do |xs|
    Prop.eq(xs.reverse.reverse, xs)
  end
end
```

A false law fails the test with the shrunk counterexample. The same check with `Prop.eq(xs.reverse, xs)` as the law
and `Prop.Config(seed: some(1234))` fails with
`falsified after 1 run, shrunk to [0,-1], seed 1234: expected [0,-1], got [-1,0]`.

## API

| | |
|---|---|
| `Prop.check(gen, config, law)` | runs `law` (a block that returns `Result[Void]`) on 100 values of `gen`; `config` is optional |
| `Prop.Config(runs: 100, seed: none, discards: 1000, shrinks: 500)` | how many cases, a fixed seed (32 bits), how many discarded cases are too many, how many laws to run when shrinking (the message says `(shrinking stopped after N steps)` when it runs out) |
| `Prop.eq(actual, expected)` | the equality for a law: `ok()`, or an `error` with both values (compared as JSON) |
| `Prop.assume(condition)` | discards the case when `condition` is false; `check` fails when more than `discards` are discarded, so a law cannot pass without being tried |
| `Prop.int(min, max)`, `Prop.float(min, max)`, `Prop.bool()` | scalars; an Int shrinks toward 0 (or the bound nearest to it) |
| `Prop.string(max_size = 10)`, `Prop.list(gen, max_size = 10)` | shrink to a shorter value, then to smaller items (a string toward `"a"`); `max_size` is at most 1000 |
| `Prop.optional(gen)`, `Prop.one_of(items)`, `Prop.pair(a, b)` | `none` or `some` (half each), `some` shrinking to `none`; one item, shrinking toward the first; a `Prop.Pair(first, second)` |
| `Prop.map(gen, f)` | the values of `gen` through `f`; they shrink as the originals do |
| `Prop.sample(gen, seed, count = 5)` | the values that `check` would try first with that seed |
| `Prop.of(codec, schema, depth = 2)` | a generator for a struct or enum that JSON can decode: `Prop.of(User.codec, JSON.schema(User))` |
| `Prop.roundtrip`, `idempotent`, `oracle`, `associative`, `commutative`, `preserves` | a law in one call, see below |
| `Prop.exhaustive(gen, size, max_cases = 10_000, law)`, `Prop.cases(gen, size)` | every case up to a size, and how many there are |

`Gen[T]` makes a shrink tree (a value and, on demand, its simpler values) from a seed, so `map` and `pair` shrink with no
inverse function.

## Laws

Each helper returns the `Result[Void]` of `check`, so it goes straight into a test. Every one takes a `Config` just
before its last function (as `check` does), which may be a block, or a `&function` reference; with no `Config` the
default one runs.

| law | holds when |
|---|---|
| `Prop.roundtrip(gen, encode, decode)` | `decode(encode(x))` is `ok(x)`; `decode` returns a `Result`, as `JSON.decode` does |
| `Prop.idempotent(gen, f)` | `f(f(x))` is `f(x)` |
| `Prop.oracle(gen, fast, slow)` | `fast(x)` is `slow(x)`: the fast code against a simple one that is obviously right |
| `Prop.associative(gen, op)` | `op(op(a, b), c)` is `op(a, op(b, c))` |
| `Prop.commutative(gen, op)` | `op(a, b)` is `op(b, a)` |
| `Prop.preserves(gen, f, measure)` | `measure(f(x))` is `measure(x)` (the size, the sum, the sortedness) |

```ruby
def encode_user(user: User) -> String
  return User.codec.encode(user)
end

def decode_user(text: String) -> Result[User]
  return User.codec.decode(text)
end

def test_user_round_trip() -> Result[Void]
  return Prop.roundtrip(Prop.of(User.codec, JSON.schema(User)), &encode_user, &decode_user)
end

def test_sort_is_idempotent() -> Result[Void]
  return Prop.idempotent(Prop.list(Prop.int(-9, 9)), Prop.Config(runs: 50)) do |xs| xs.sort end
end
```

Equality is `Prop.eq`: the values are compared as JSON, so they must be JSON-encodable, and two maps with the same
pairs in a different order differ. A failure names the law and both values:
`fast(x) differs from slow(x): expected 1, got 0`.

## Generators for your types

`Prop.of(codec, schema)` makes values of a struct or enum that JSON can decode. Agentica cannot read a type from a
codec (`codec.members` lists the fields of a struct as text, and nothing for an enum), so the JSON Schema is passed as
well: `T.codec` and `JSON.schema(T)` of the same type. The generator makes the JSON that the schema allows, and the
codec decodes it, so a value is always one `T` can have.

- Int is in -1000 ..= 1000, Float in -1000.0 ..= 1000.0, strings as `Prop.string()`, lists up to 3 items. A map has
  up to 3 pairs with random keys (up to 4 characters, the empty one too) when `check` draws it; `exhaustive` goes over
  the maps that hold or leave out each of the keys `"a"`, `"b"` and `"é 漢"`, so two cases are never the same map. Every field is
  made, an `Optional` is `none` half of the time, and an enum picks a variant.
- A key that is missing from the JSON is never made: an `Optional` or defaulted field is always present (with `null` for
  `none`), and a `JsonField` is never `Absent`. That input is not covered by `Prop.of`; test it in a plain `test_` with
  `T.codec.decode` of a text without the key. It also keeps the cases of an exhaustive check distinct.
- Shrinking goes through the parts: an `Optional` to `none`, a list to fewer items, a variant to an earlier one, a number
  toward 0.
- A type that holds itself (through a list, a map, an `Optional` or a variant) nests at most `depth` times; the list,
  the map, the `Optional` or the variant that ends it is chosen after that. A type that cannot end (a required field of
  its own type) halts.
- A case of a struct with six fields, a nested struct and an enum takes about 5000 steps, and one of a `Tree` (a value
  and a list of trees) 4000 at depth 2 and 7000 at depth 3, before the law runs: with the budget of a test (below), keep
  `depth` small and `runs` at a few hundred.
- A schema of another type than the codec's halts the test with the decode error.

## Exhaustive check

`Prop.exhaustive(gen, size, law)` tries every case `gen` has up to `size`, smallest first, instead of a random sample.
It returns `ok()` when all hold; the report is "all N cases up to size k", with N from `Prop.cases(gen, k)`, and it never
means the law is proved: a bigger size can still break it. A false law is `falsified at size 2, counterexample [1,2]:
...` from the smallest size that has one.

The size of a case, by generator: an Int or a Float is up to k away from the value nearest to 0 (a Float on the
whole numbers); a list has up to k items, each at size k; a string up to k characters from the first k + 1 letters; an
`Optional` is `none` or a value at size k; a pair or a `Prop.of` struct is every combination; `one_of` and `bool` have
all their values at every size.

`max_cases` (10_000) is checked before anything runs, and a size with more cases is an `error` that says how many ("at least 1000000000" when the count hit its cap):
the cases of a list grow as the power of its items, and a test has a step budget (below). A case discarded with
`Prop.assume` is skipped; a law that skips them all is an error. There is no seed, and no `Config`: the cases are the
same every run.

## Seeds and replay

`check` draws its seed from the test's `Random`, so `agentica --seed N test` replays the whole run, and a case depends on
its seed alone. The seed of a failure is in the message: `Prop.Config(seed: some(1234))` runs that check again and
nothing else. Report a result as "tested with N cases, seed S", never as proved.

## Rules for a law

- Fail with `Prop.eq`, `Prop.assume` or `error(...)`. A failed `Test.eq` or `Test.assert` inside a law fails the test at
  the first failing case, before `check` can shrink it.
- Do not narrow a generator, or weaken the law, to make it pass: put the counterexample in a plain `test_` and fix the
  code.
- A test has a budget of about 2.5 million steps (and 30 s), and a run that exceeds it ends with `RUNTIME-STEP-LIMIT`,
  which `check` cannot catch: the counterexample and the seed are lost. Making a case costs about 200 steps per item
  (a string is a list of characters, a list of strings a list of lists), so 100 cases of `list(string())` take about
  0.5 million, 100 cases of `list(int(0, 1000), 100)` about 0.7 million, and `list(string(20), 20)` about 1.5 million
  before the law runs. Raise `max_size` or `runs` only as far as that allows, or split the law into several tests.
- `Prop.eq` and the counterexample use `JSON.encode`, so the generated type must be JSON-encodable, and two maps with the
  same pairs in another order differ.

## Agent guide

For an AI that writes Agentica, after the AGENTS.md of [josevalim/lynx](https://github.com/josevalim/lynx): state what a
function must do as laws, and let the tests find where it does not.

1. State at least one law for each public function: a round trip, idempotence, an oracle (a slow, obviously right
   version), an invariant (`preserves`), or at least "does not crash" (`Prop.check` with a law that only calls it
   and returns `ok()`). Put the laws in `test/`, apart from the code: the law is the specification, so it is not
   written from the code it checks.
2. When a law fails, the message has the shrunk counterexample and the seed. Copy the counterexample into a plain
   `test_` function (it stays a test when the generator changes), then fix the code.
3. Never weaken the law, narrow the generator, raise `discards` or lower `runs` to make a test pass. If the law is
   wrong for some inputs, say which ones with `Prop.assume` and keep that in the report.
4. Report what was done, not what is proved: "tested with 100 cases, seed 1234, discards 0", or "all 15 cases up to size
   3". A passing `check` returns plain `ok()` with no seed, so to report S, pin it: `Prop.Config(seed: some(1234))`
   (the seed of a failure is in its message). D is the number of cases the law's `Prop.assume` dropped, which `check`
   does not return either: say 0 only when the law has no `assume`. Never write "proved", "verified" or "correct for
   all inputs".
