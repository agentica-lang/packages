import Prop from "../prop"

private

# A plain law: `Test.assert` here would fail the test at the first case, before `check` shrinks it.
def must(condition: Bool, text: String) -> Result[Void]
  return ok() if condition

  error(text)
end

def seeded(seed: Int) -> Prop.Config = Prop.Config(seed: some(seed), runs: 300)

# Whether the failure of a check names `counterexample` as the shrunk value.
def shrunk_to(result: Result[Void], counterexample: String) -> Result[Void]
  Test.assert(result.message.include?("shrunk to #{counterexample},"), "got: #{result.message}")
end

# The value after "shrunk to " in the message of a check.
def shrunk_float(result: Result[Void]) -> Float = result.message.split("shrunk to ")[1].split(",")[0].to_f!

def test_a_false_law_over_lists_shrinks_to_one_item() -> Result[Void]
  result = Prop.check(Prop.list(Prop.int(0, 100)), seeded(1)) do |xs|
    must(xs.all? do |x| x <= 50 end, "an item is above 50")
  end

  try Test.assert(result.message.start_with?("falsified after "), result.message)
  try Test.assert(result.message.include?("seed 1:"), result.message)
  shrunk_to(result, "[51]")
end

def test_each_generator_shrinks_to_its_simplest_failing_value() -> Result[Void]
  negative = Prop.check(Prop.int(-50, 50), seeded(2)) do |n| must(n > -7, "n is -7 or less") end
  try shrunk_to(negative, "-7")
  clamped = Prop.check(Prop.int(5, 100), seeded(3)) do |_| must(false, "always") end
  try shrunk_to(clamped, "5")
  text = Prop.check(Prop.string(), seeded(4)) do |s| must(s.length < 3, "three characters or more") end
  try shrunk_to(text, "\"aaa\"")
  both = Prop.check(Prop.pair(Prop.int(0, 99), Prop.int(0, 99)), seeded(5)) do |p|
    must(p.first < 5 or p.second < 5, "both are 5 or more")
  end

  try shrunk_to(both, "{\"first\":5,\"second\":5}")
  chosen = Prop.check(Prop.one_of(["a", "b", "c", "d"]), seeded(6)) do |s| must(s.compare("c") < 0, "c or later") end
  try shrunk_to(chosen, "\"c\"")
  doubled = Prop.check(Prop.map(Prop.int(0, 100)) do |n| n * 2 end, seeded(7)) do |n| must(n < 100, "100 or more") end
  try shrunk_to(doubled, "100")
  floats = Prop.check(Prop.float(0.0, 100.0), seeded(8)) do |x| must(x < 10.0, "10.0 or more") end
  shrunk_to(floats, "10.0")
end

def test_a_discarded_case_is_not_a_counterexample() -> Result[Void]
  result = Prop.check(Prop.int(0, 100), seeded(9)) do |n|
    try Prop.assume(n > 20)
    must(n < 30, "30 or more")
  end

  shrunk_to(result, "30")
end

def test_a_true_law_passes() -> Result[Void]
  gen = Prop.list(Prop.optional(Prop.int(-100, 100)))
  Prop.check(gen) do |xs| Prop.eq(xs.reverse.reverse, xs) end
end

# The default 100 runs of a list of strings must fit the step budget of a test.
def test_a_true_law_over_lists_of_strings_passes_with_the_default_config() -> Result[Void]
  Prop.check(Prop.list(Prop.string())) do |xs| Prop.eq(xs.reverse.reverse, xs) end
end

# Every candidate is closer to 0, so the value does not bounce between -0.5 and -1.0 until the budget ends.
def test_a_negative_float_shrinks_to_a_value_next_to_zero() -> Result[Void]
  result = Prop.check(Prop.float(-10.0, 10.0), seeded(3)) do |x| must(x >= 0.0, "negative") end
  try Test.assert(not result.message.include?("shrinking stopped"), result.message)
  try Test.assert(result.message.include?("shrunk to -"), result.message)
  Test.assert(result.message.include?("e-"), "not next to zero: #{result.message}")
end

# A float shrinks within [min, max]: with an origin that is not a whole number, rounding must not cross it.
def test_a_float_shrinks_inside_its_range() -> Result[Void]
  result = Prop.check(Prop.float(0.1, 10.0), Prop.Config(seed: some(2), runs: 300)) do |x|
    must(x == 0.1 or x >= 0.99, "inside")
  end

  try Test.assert(shrunk_float(result) > 0.1, result.message)
  try Test.assert(shrunk_float(result) < 0.99, result.message)
  Test.assert(not result.message.include?("shrinking stopped"), result.message)
end

# Past 2^53 a step that is under half an ulp moves nothing: it must not be offered, or the budget goes on one value.
def test_a_large_float_shrinks_without_spending_the_budget() -> Result[Void]
  config = Prop.Config(seed: some(2))
  result = Prop.check(Prop.float(0.0, 1.0e15), config) do |x| must(x < 1.0e12, "1e12 or more") end
  try shrunk_to(result, "1000000000000.0")
  Test.assert(not result.message.include?("shrinking stopped"), result.message)
end

def test_a_seed_beyond_32_bits_is_masked() -> Result[Void]
  huge = 9223372036854775807
  gen = Prop.list(Prop.int(0, 99))
  try Test.eq(Prop.sample(gen, huge, 5), Prop.sample(gen, 0xFFFFFFFF, 5))
  falsified = Prop.check(Prop.int(0, 9), Prop.Config(seed: some(huge))) do |n| must(n < 5, "5 or more") end
  try Test.assert(falsified.message.include?("seed #{huge}"), falsified.message)
  Prop.check(Prop.int(0, 9), Prop.Config(seed: some(-huge))) do |n| must(n < 10, "never") end
end

def test_an_optional_shrinks_to_none_and_then_through_its_value() -> Result[Void]
  gen = Prop.optional(Prop.int(0, 9))
  nothing = Prop.check(gen, seeded(12)) do |_| must(false, "always") end
  try shrunk_to(nothing, "null")
  something = Prop.check(gen, seeded(13)) do |o| must(o.none? or o.unwrap! < 4, "4 or more") end
  try shrunk_to(something, "4")
  halves = Prop.sample(gen, 1, 400)
  nones = halves.select do |o| o.none? end
  Test.assert(nones.size > 120, "far fewer none than some")
end

def test_the_shrinking_budget_ends_with_a_message() -> Result[Void]
  config = Prop.Config(seed: some(21), shrinks: 5)
  result = Prop.check(Prop.list(Prop.int(0, 1000), 60), config) do |xs| must(xs.size < 1, "not empty") end
  Test.assert(result.message.include?("(shrinking stopped after 5 steps)"), result.message)
end

def test_the_same_seed_makes_the_same_cases() -> Result[Void]
  gen = Prop.pair(Prop.string(), Prop.list(Prop.optional(Prop.float(-1.0, 1.0))))
  try Test.eq(Prop.sample(gen, 7, 40), Prop.sample(gen, 7, 40))
  try Test.assert(Prop.sample(gen, 7, 40) != Prop.sample(gen, 8, 40), "two seeds made the same cases")
  first = Prop.check(Prop.list(Prop.int(0, 1000)), seeded(11), &small_sum)
  second = Prop.check(Prop.list(Prop.int(0, 1000)), seeded(11), &small_sum)
  try Test.assert(not first.ok?, "the law holds")
  Test.eq(first, second)
end

def test_too_many_discards_fail_the_check() -> Result[Void]
  result = Prop.check(Prop.int(0, 10), Prop.Config(discards: 50)) do |_| Prop.assume(false) end
  try Test.assert(result.message.start_with?("gave up: 51 cases discarded and 0 of 100 passed"), result.message)
  half = Prop.check(Prop.int(0, 10), Prop.Config(discards: 500)) do |n|
    try Prop.assume(n % 2 == 0)
    ok()
  end

  Test.ok?(half)
end

def test_generators_stay_in_their_bounds() -> Result[Void]
  ints = Prop.sample(Prop.int(-5, 5), 1, 400)
  try Test.eq(ints.min, some(-5))
  try Test.eq(ints.max, some(5))
  lists = Prop.sample(Prop.list(Prop.bool(), 3), 1, 200)
  sizes = lists.map do |xs| xs.size end
  try Test.eq(sizes.max, some(3))
  options = Prop.sample(Prop.optional(Prop.int(0, 0)), 1, 200)
  try Test.assert(options.any? do |o| o.none? end and options.any? do |o| o.some? end, "one kind is missing")
  texts = Prop.sample(Prop.string(4), 1, 200)
  try Test.assert(texts.all? do |s| s.length <= 4 end, "a string is longer than 4")
  floats = Prop.sample(Prop.float(-2.5, 2.5), 1, 200)
  Test.assert(floats.all? do |x| x >= -2.5 and x <= 2.5 end, "a float is out of range")
end

def small_sum(xs: List[Int]) -> Result[Void] = must(xs.sum < 1500, "the sum is 1500 or more")
