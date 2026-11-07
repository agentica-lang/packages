## Bounded exhaustive checking (SmallCheck style): try every case a generator has up to a size.

import Checks from "check"
import Gens from "gen"

## How many cases `Prop.exhaustive` tries for `gen` up to `size` (it stops counting at 1_000_000_000).
export def cases[T](gen: Gens.Gen[T], size: Int) -> Int
  return gen.count(size)
end

## Runs `law` on every value of `gen` up to `size` and returns `ok()` when all of them hold: "all N cases up to size k"
## (`Prop.cases` gives N), not that the law is proved, because a bigger size may still falsify it. A false law is an
## `error` with the counterexample of the smallest size that has one. What a size means is in each generator (items of
## a list, distance of an Int from 0). `max_cases` stops a size that is too big before it runs, because a test has a
## step budget. A case that fails with `Prop.assume` is skipped, and a law that skips all of them is an error.
export def exhaustive[T](
  gen: Gens.Gen[T],
  size: Int,
  max_cases: Int = 10_000,
  law: Fn[T, Result[Void]],
) -> Result[Void]
  if size < 0
    return error("Prop.exhaustive: size must be at least 0, got #{size}")
  end

  total = gen.count(size)
  if total > max_cases
    atleast = counted(total)
    return error("Prop.exhaustive: #{atleast} cases up to size #{size} is more than max_cases #{max_cases}")
  end

  skipped = 0
  for value in gen.all(size)
    verdict = law.call(value)
    if Checks.discarded?(verdict)
      skipped += 1
    elsif not verdict.ok?
      return smallest(gen, size, law)
    end
  end

  if skipped == total
    return error("gave up: all #{total} cases up to size #{size} were discarded")
  end

  return ok()
end

# The case that failed is not the simplest one, as the cases of a size are not in order of size: the smaller sizes
# run again, so the counterexample is from the smallest size that has one and every case below it passed.
def smallest[T](gen: Gens.Gen[T], size: Int, law: Fn[T, Result[Void]]) -> Result[Void]
  for at in 0..size
    for value in gen.all(at)
      verdict = law.call(value)
      if not verdict.ok? and not Checks.discarded?(verdict)
        return error("falsified at size #{at}, counterexample #{JSON.encode(value)}: #{verdict.message}")
      end
    end
  end

  return error("Prop.exhaustive: the law passed on the rerun up to size #{size}, so it is not deterministic")
end

# A count that reached the cap is a lower bound, not the number of cases.
def counted(total: Int) -> String
  if Gens.capped?(total)
    return "at least #{total}"
  end

  return total.to_s
end
