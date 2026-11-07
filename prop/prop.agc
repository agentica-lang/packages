## Property-based testing: state a law, check it on many generated inputs, and get the smallest input that breaks it.
##
## ```ruby
## import Prop from "pkg/prop/prop"
##
## def test_reverse_twice() -> Result[Void]
##   return Prop.check(Prop.list(Prop.int(-100, 100))) do |xs|
##     Prop.eq(xs.reverse.reverse, xs)
##   end
## end
## ```
##
## A failure is `falsified after 37 runs, shrunk to [3,0], seed 1234: ...`. `agentica --seed N test` replays the whole
## run; `Prop.Config(seed: some(1234))` replays one check. `Prop.roundtrip`, `idempotent`, `oracle`, `associative`,
## `commutative` and `preserves` state the common laws in one call, `Prop.of(User.codec, JSON.schema(User))` makes
## values of a struct or enum, and `Prop.exhaustive` tries every case up to a size.

import Checks from "src/check"
import Exhaustive from "src/exhaustive"
import Gens from "src/gen"
import Laws from "src/laws"
import Schema from "src/schema"

export Checks.Config
export Checks.check
export Checks.assume
export Checks.eq
export Gens.Gen
export Gens.Pair
export Gens.int
export Gens.float
export Gens.bool
export Gens.string
export Gens.list
export Gens.optional
export Gens.one_of
export Gens.map
export Gens.pair
export Gens.sample
export Laws.roundtrip
export Laws.idempotent
export Laws.oracle
export Laws.associative
export Laws.commutative
export Laws.preserves
export Exhaustive.exhaustive
export Exhaustive.cases
export Schema.of
