## The runner: draw a case from a seed, run the law, and shrink the first case that falsifies it.

import Gens from "gen"
import Seeds from "seed"
import Trees from "tree"

# `Prop.assume` fails with this text, and a law that fails with exactly it is discarded, not falsified.
DISCARD = "prop: case discarded"
# The most laws run to shrink one counterexample: a law that is slow or a shrink that never ends still stops.
MAX_SHRINKS = 1000
MAX_SEED = 2147483647

## How `Prop.check` runs.
export struct Config
  runs: Int = 100
  seed: Optional[Int] = none
  discards: Int = 1000
end

## The smallest counterexample found, and the message of the law for it.
struct Shrunk[T]
  value: T
  message: String
end

## Runs `law` on `config.runs` values of `gen` and returns `ok()`, or an `error` that names the shrunk counterexample
## and the seed: `falsified after 37 runs, shrunk to [3,0], seed 1234: expected ...`. The seed is drawn from `Random`
## (so `agentica --seed N test` replays the run), or is `config.seed`, which replays the check alone. A case that fails
## with `Prop.assume` is discarded; more than `config.discards` of them is an `error`, so a law cannot pass without
## being tried. The law should fail with `Prop.eq`, `Prop.assume` or `error(...)`: a failed `Test.eq` or `Test.assert`
## fails the test at the first case, before it is shrunk.
export def check[T](gen: Gens.Gen[T], config: Config = Config(), law: Fn[T, Result[Void]]) -> Result[Void]
  if config.runs < 1
    return error("Prop.check: runs must be at least 1, got #{config.runs}")
  end

  seed = config.seed.unwrap_or(Random.int(0, MAX_SEED))
  passed = 0
  discarded = 0
  attempt = 0
  while passed < config.runs
    tree = gen.make(Seeds.split(seed, attempt))
    attempt += 1
    verdict = law.call(tree.value)
    if verdict.ok?
      passed += 1
    elsif verdict.message == DISCARD
      discarded += 1
      if discarded > config.discards
        return error("gave up: #{discarded} cases discarded and #{passed} of #{config.runs} passed, seed #{seed}")
      end
    else
      found = shrink(tree, verdict.message, law)
      runs = count(passed + 1, "run")
      message = "falsified after #{runs}, shrunk to #{JSON.encode(found.value)}, seed #{seed}: #{found.message}"
      return error(message)
    end
  end

  return ok()
end

## Discards the case when `condition` is false. Use it first in a law, for the inputs it does not cover.
export def assume(condition: Bool) -> Result[Void]
  if condition
    return ok()
  end

  return error(DISCARD)
end

## `ok()` when both values encode to the same JSON, else an `error` with both. Unlike `Test.eq` a failure here is a
## plain `Result`, so `check` can shrink it. Two maps with the same pairs in another order differ.
export def eq[T](actual: T, expected: T) -> Result[Void]
  got = JSON.encode(actual)
  want = JSON.encode(expected)
  if got == want
    return ok()
  end

  return error("expected #{want}, got #{got}")
end

def count(n: Int, noun: String) -> String
  if n == 1
    return "#{n} #{noun}"
  end

  return "#{n} #{noun}s"
end

# Walks down the tree: at each step takes the first child that still falsifies the law, until none does.
def shrink[T](tree: Trees.Tree[T], message: String, law: Fn[T, Result[Void]]) -> Shrunk[T]
  current = tree
  current_message = message
  budget = MAX_SHRINKS
  while budget > 0
    smaller = false
    for child in current.children()
      budget -= 1
      verdict = law.call(child.value)
      if not verdict.ok? and verdict.message != DISCARD
        current = child
        current_message = verdict.message
        smaller = true
        break
      end

      if budget == 0
        break
      end
    end

    if not smaller
      break
    end
  end

  return Shrunk(value: current.value, message: current_message)
end
