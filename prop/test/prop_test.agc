import Prop from "../prop"

# A plain law: `Test.assert` here would fail the test at the first case, before `check` shrinks it.
def must(condition: Bool, text: String) -> Result[Void]
  if condition
    return ok()
  end

  return error(text)
end

def seeded(seed: Int) -> Prop.Config
  return Prop.Config(seed: some(seed), runs: 300)
end

# Whether the failure of a check names `counterexample` as the shrunk value.
def shrunk_to(result: Result[Void], counterexample: String) -> Result[Void]
  return Test.assert(result.message.include?("shrunk to #{counterexample},"), "got: #{result.message}")
end

def test_a_false_law_over_lists_shrinks_to_one_item() -> Result[Void]
  result = Prop.check(Prop.list(Prop.int(0, 100)), seeded(1)) do |xs|
    must(xs.all? do |x| x <= 50 end, "an item is above 50")
  end

  try Test.assert(result.message.start_with?("falsified after "), result.message)
  try Test.assert(result.message.include?("seed 1:"), result.message)
  return shrunk_to(result, "[51]")
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
  return shrunk_to(floats, "10.0")
end

def test_a_discarded_case_is_not_a_counterexample() -> Result[Void]
  result = Prop.check(Prop.int(0, 100), seeded(9)) do |n|
    try Prop.assume(n > 20)
    must(n < 30, "30 or more")
  end

  return shrunk_to(result, "30")
end

def test_a_true_law_passes() -> Result[Void]
  gen = Prop.list(Prop.optional(Prop.int(-100, 100)))
  return Prop.check(gen) do |xs| Prop.eq(xs.reverse.reverse, xs) end
end

def test_the_same_seed_makes_the_same_cases() -> Result[Void]
  gen = Prop.pair(Prop.string(), Prop.list(Prop.optional(Prop.float(-1.0, 1.0))))
  try Test.eq(Prop.sample(gen, 7, 40), Prop.sample(gen, 7, 40))
  try Test.assert(Prop.sample(gen, 7, 40) != Prop.sample(gen, 8, 40), "two seeds made the same cases")
  first = Prop.check(Prop.list(Prop.int(0, 1000)), seeded(11), &small_sum)
  second = Prop.check(Prop.list(Prop.int(0, 1000)), seeded(11), &small_sum)
  try Test.assert(not first.ok?, "the law holds")
  return Test.eq(first, second)
end

def test_too_many_discards_fail_the_check() -> Result[Void]
  result = Prop.check(Prop.int(0, 10), Prop.Config(discards: 50)) do |_| Prop.assume(false) end
  try Test.assert(result.message.start_with?("gave up: 51 cases discarded and 0 of 100 passed"), result.message)
  half = Prop.check(Prop.int(0, 10), Prop.Config(discards: 500)) do |n|
    try Prop.assume(n % 2 == 0)
    ok()
  end

  return Test.ok?(half)
end

def test_generators_stay_in_their_bounds() -> Result[Void]
  ints = Prop.sample(Prop.int(-5, 5), 1, 400)
  try Test.eq(ints.min, some(-5))
  try Test.eq(ints.max, some(5))
  lists = Prop.sample(Prop.list(Prop.bool(), 3), 1, 200)
  try Test.eq(lists.map do |xs| xs.size end.max, some(3))
  options = Prop.sample(Prop.optional(Prop.int(0, 0)), 1, 200)
  try Test.assert(options.any? do |o| o.none? end and options.any? do |o| o.some? end, "one kind is missing")
  texts = Prop.sample(Prop.string(4), 1, 200)
  try Test.assert(texts.all? do |s| s.length <= 4 end, "a string is longer than 4")
  floats = Prop.sample(Prop.float(-2.5, 2.5), 1, 200)
  return Test.assert(floats.all? do |x| x >= -2.5 and x <= 2.5 end, "a float is out of range")
end

def small_sum(xs: List[Int]) -> Result[Void]
  return must(xs.sum < 1500, "the sum is 1500 or more")
end
