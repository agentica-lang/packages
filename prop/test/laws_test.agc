import Prop from "../prop"

struct Point
  x: Int
  y: Float
end

enum Shape
  Dot
  Circle(Float)
  Rect(Int, String)
end

struct Item
  name: String
  tags: List[String]
  shape: Shape
  at: Optional[Point]
  sizes: Map[String, Int]
  done: Bool
end

struct Tree
  value: Int
  kids: List[Tree]
end

struct Bag
  entries: Map[String, Bool]
end

struct Ping
  pong: Optional[Pong]
end

struct Pong
  ping: Optional[Ping]
  n: Int
end

def seeded(seed: Int) -> Prop.Config = Prop.Config(seed: some(seed), runs: 200)

def ints() -> Prop.Gen[List[Int]] = Prop.list(Prop.int(0, 9))

# The value after "shrunk to " in the message of a check, and the reason that follows it.
def shrunk_to(result: Result[Void], counterexample: String) -> Result[Void]
  Test.assert(result.message.include?("shrunk to #{counterexample},"), "got: #{result.message}")
end

def falsified(result: Result[Void], counterexample: String, reason: String) -> Result[Void]
  try shrunk_to(result, counterexample)
  Test.assert(result.message.include?(reason), "got: #{result.message}")
end

def sign_lost(n: Int) -> String = n.abs.to_s

def sign_kept(n: Int) -> String = n.to_s

def read_int(text: String) -> Result[Int] = text.to_i

def sorted(xs: List[Int]) -> List[Int] = xs.sort

def swapped(xs: List[Int]) -> List[Int] = xs.reverse

def sum_of(xs: List[Int]) -> Int = xs.sum

def first_two_sum(xs: List[Int]) -> Int = xs.take(2).sum

def count_of(xs: List[Int]) -> Int = xs.size

def first_three(xs: List[Int]) -> List[Int] = xs.take(3)

def plus(a: Int, b: Int) -> Int = a + b

def minus(a: Int, b: Int) -> Int = a - b

def larger(a: Int, b: Int) -> Int = [a, b].max.unwrap!

def has_a_tree_under(tree: Tree) -> Result[Void] = Prop.eq(tree.kids.empty?, true)

def small_x(point: Point) -> Result[Void] = Prop.eq(point.x < 5, true)

def not_a_rect(shape: Shape) -> Result[Void]
  case shape
    Shape.Rect(_, _) -> error("a Rect")
    _ -> ok()
  end
end

def item_round_trips(item: Item) -> Result[Void] = Prop.eq(Item.codec.decode(Item.codec.encode(item)).unwrap!, item)

def decode_item(text: String) -> Result[Item] = Item.codec.decode(text)

def encode_item(item: Item) -> String = Item.codec.encode(item)

def always(_: Int) -> Result[Void] = ok()

# `count` is how many cases `all` has, and no two of them are the same.
def counted_and_distinct[T](gen: Prop.Gen[T], size: Int) -> Result[Void]
  cases = gen.all(size)
  texts = cases.map do |value| JSON.encode(value) end
  try Test.eq(gen.count(size), cases.size)
  Test.eq(texts.uniq.size, texts.size)
end

def total_below_five(xs: List[Int]) -> Result[Void] = Prop.eq(xs.sum < 5, true)

def everything_is_skipped(_: Int) -> Result[Void] = Prop.assume(false)

def test_roundtrip_passes_and_a_lossy_encoding_shrinks_to_minus_one() -> Result[Void]
  try Prop.roundtrip(Prop.int(-100, 100), &sign_kept, &read_int)
  lossy = Prop.roundtrip(Prop.int(-100, 100), &sign_lost, seeded(1), &read_int)
  falsified(lossy, "-1", "decode(encode(x)) differs from x: expected -1, got 1")
end

def test_roundtrip_reports_a_decode_error() -> Result[Void]
  result = Prop.roundtrip(Prop.int(0, 9), &sign_kept, seeded(2)) do |text| error("no #{text}") end
  falsified(result, "0", "decode(encode(x)) failed: no 0")
end

def test_idempotent_passes_for_sort_and_fails_for_reverse() -> Result[Void]
  try Prop.idempotent(ints(), &sorted)
  result = Prop.idempotent(ints(), seeded(3), &swapped)
  shrunk_to(result, "[0,1]")
end

def test_oracle_passes_and_a_fast_version_that_skips_items_shrinks() -> Result[Void]
  try Prop.oracle(ints(), &sum_of, &sum_of)
  result = Prop.oracle(ints(), &first_two_sum, seeded(4), &sum_of)
  falsified(result, "[0,0,1]", "fast(x) differs from slow(x): expected 1, got 0")
end

def test_associative_holds_for_plus_and_fails_for_minus() -> Result[Void]
  try Prop.associative(Prop.int(-50, 50), &plus)
  result = Prop.associative(Prop.int(-50, 50), seeded(5), &minus)
  shrunk_to(result, "{\"a\":0,\"b\":0,\"c\":1}")
end

def test_commutative_holds_for_the_larger_and_fails_for_minus() -> Result[Void]
  try Prop.commutative(Prop.int(-50, 50), &larger)
  result = Prop.commutative(Prop.int(-50, 50), seeded(6), &minus)
  shrunk_to(result, "{\"a\":0,\"b\":1}")
end

def test_preserves_holds_for_reverse_and_fails_for_take() -> Result[Void]
  try Prop.preserves(ints(), &swapped, &count_of)
  result = Prop.preserves(ints(), &first_three, seeded(7), &count_of)
  shrunk_to(result, "[0,0,0,0]")
end

def test_exhaustive_counts_the_cases_up_to_a_size() -> Result[Void]
  try Test.eq(Prop.cases(Prop.bool(), 0), 2)
  try Test.eq(Prop.cases(Prop.int(-5, 5), 2), 5)
  try Test.eq(Prop.cases(Prop.int(0, 100), 3), 4)
  try Test.eq(Prop.cases(Prop.list(Prop.bool()), 3), 15)
  try Test.eq(Prop.cases(Prop.pair(Prop.bool(), Prop.int(0, 9)), 2), 6)
  try Test.eq(Prop.cases(Prop.optional(Prop.int(0, 9)), 2), 4)
  try Test.eq(Prop.cases(Prop.list(Prop.int(0, 9)), 2), 1 + 3 + 9)
  try Test.eq(Prop.cases(Prop.string(), 2), 1 + 3 + 9)
  Test.eq(Prop.cases(Prop.one_of(["a", "b", "c"]), 0), 3)
end

def test_exhaustive_passes_when_every_case_holds() -> Result[Void]
  try Prop.exhaustive(Prop.list(Prop.bool()), 4) do |xs| Prop.eq(xs.reverse.reverse, xs) end
  Prop.exhaustive(Prop.pair(Prop.int(-3, 3), Prop.int(-3, 3)), 3) do |p|
    Prop.eq(p.first + p.second, p.second + p.first)
  end
end

def test_exhaustive_reports_the_counterexample_of_the_smallest_size() -> Result[Void]
  result = Prop.exhaustive(Prop.list(Prop.int(0, 3)), 3, &total_below_five)
  Test.eq(result.message, "falsified at size 3, counterexample [2,3]: expected true, got false")
end

def test_exhaustive_refuses_a_size_with_too_many_cases_and_all_skipped_cases() -> Result[Void]
  big = Prop.exhaustive(Prop.list(Prop.int(0, 9)), 6, &total_below_five)
  try Test.assert(big.message.include?("137257 cases up to size 6 is more than max_cases 10000"), big.message)
  small = Prop.exhaustive(Prop.list(Prop.int(0, 9)), 4, 100, &total_below_five)
  try Test.assert(small.message.include?("781 cases"), small.message)
  none_left = Prop.exhaustive(Prop.int(0, 9), 2, &everything_is_skipped)
  try Test.assert(none_left.message.start_with?("gave up: all 3 cases"), none_left.message)
  negative = Prop.exhaustive(Prop.int(0, 9), -1, &everything_is_skipped)
  Test.assert(negative.message.include?("size must be at least 0"), negative.message)
end

def test_of_makes_values_that_round_trip_through_the_codec() -> Result[Void]
  gen = Prop.of(Item.codec, JSON.schema(Item))
  config = Prop.Config(seed: some(8), runs: 100)
  try Prop.check(gen, config, &item_round_trips)
  Prop.roundtrip(gen, &encode_item, config, &decode_item)
end

def test_of_covers_every_part_of_a_type() -> Result[Void]
  items = Prop.sample(Prop.of(Item.codec, JSON.schema(Item)), 3, 60)
  try Test.assert(items.any? do |item| item.at.some? end and items.any? do |item| item.at.none? end, "at is stuck")
  try Test.assert(items.any? do |item| item.sizes.size > 0 end, "sizes is always empty")
  try Test.assert(items.any? do |item| item.tags.size > 0 end, "tags is always empty")
  shapes = items.map do |item| JSON.encode(item.shape) end
  try Test.assert(shapes.any? do |s| s.include?("Dot") end, "no Dot")
  try Test.assert(shapes.any? do |s| s.include?("Circle") end, "no Circle")
  Test.assert(shapes.any? do |s| s.include?("Rect") end, "no Rect")
end

def test_of_shrinks_a_struct_and_an_enum_to_their_simplest_failing_value() -> Result[Void]
  points = Prop.check(Prop.of(Point.codec, JSON.schema(Point)), seeded(10), &small_x)
  try shrunk_to(points, "{\"x\":5,\"y\":0.0}")
  shapes = Prop.check(Prop.of(Shape.codec, JSON.schema(Shape)), seeded(11), &not_a_rect)
  shrunk_to(shapes, "{\"tag\":\"Rect\",\"values\":[0,\"\"]}")
end

def test_of_ends_a_recursive_type_at_its_depth() -> Result[Void]
  gen = Prop.of(Tree.codec, JSON.schema(Tree), 1)
  result = Prop.check(gen, seeded(12), &has_a_tree_under)
  try shrunk_to(result, "{\"value\":0,\"kids\":[{\"value\":0,\"kids\":[]}]}")
  deep = Prop.sample(Prop.of(Tree.codec, JSON.schema(Tree), 4), 5, 60)
  Test.assert(deep.all? do |tree| JSON.encode(tree).size < 20_000 end, "a tree is too big")
end

def test_exhaustive_goes_over_the_cases_of_of() -> Result[Void]
  gen = Prop.of(Point.codec, JSON.schema(Point))
  try Test.eq(Prop.cases(gen, 1), 9)
  Prop.exhaustive(gen, 1) do |p| Prop.eq(Point.codec.decode(Point.codec.encode(p)).unwrap!, p) end
end

def test_every_case_is_counted_once_and_the_count_is_exact() -> Result[Void]
  try counted_and_distinct(Prop.list(Prop.optional(Prop.int(0, 9))), 2)
  try counted_and_distinct(Prop.pair(Prop.list(Prop.bool()), Prop.optional(Prop.int(0, 9))), 2)
  try counted_and_distinct(Prop.of(Bag.codec, JSON.schema(Bag)), 2)
  try counted_and_distinct(Prop.of(Pong.codec, JSON.schema(Pong)), 1)
  Test.eq(Prop.cases(Prop.of(Bag.codec, JSON.schema(Bag)), 2), 27)
end

def test_max_cases_is_inclusive() -> Result[Void]
  gen = Prop.list(Prop.bool())
  try Prop.exhaustive(gen, 3, 15, &always_list)
  refused = Prop.exhaustive(gen, 3, 14, &always_list)
  Test.assert(refused.message.include?("15 cases up to size 3 is more than max_cases 14"), refused.message)
end

def test_a_count_stops_at_the_cap_and_never_overflows() -> Result[Void]
  wide = Prop.int(-1_000_000_000_000_000_000, 1_000_000_000_000_000_000)
  try Test.eq(Prop.cases(wide, 4_000_000_000), 1_000_000_000)
  try Test.eq(Prop.cases(Prop.pair(wide, wide), 4_000_000_000), 1_000_000_000)
  try Test.eq(Prop.cases(Prop.pair(Prop.pair(wide, wide), wide), 4_000_000_000), 1_000_000_000)
  try Test.eq(Prop.cases(Prop.list(wide), 4_000_000_000), 1_000_000_000)
  refused = Prop.exhaustive(wide, 4_000_000_000, &always)
  Test.assert(refused.message.include?("at least 1000000000 cases"), refused.message)
end

def test_of_makes_a_mutually_recursive_type() -> Result[Void]
  gen = Prop.of(Pong.codec, JSON.schema(Pong))
  config = Prop.Config(seed: some(14), runs: 100)
  Prop.roundtrip(gen, &encode_pong, config, &decode_pong)
end

def always_list(_: List[Bool]) -> Result[Void] = ok()

def encode_pong(pong: Pong) -> String = Pong.codec.encode(pong)

def decode_pong(text: String) -> Result[Pong] = Pong.codec.decode(text)

def only_the_fixed_keys(bag: Bag) -> Result[Void]
  fixed = Set.new(["a", "b", "é 漢"])
  Prop.eq(bag.entries.keys.all? do |key| fixed.include?(key) end, true)
end

# `check` draws random keys (empty, long, "ab" beside "a"), not only the fixed ones of an exhaustive check.
def test_random_maps_of_of_have_random_keys() -> Result[Void]
  gen = Prop.of(Bag.codec, JSON.schema(Bag))
  result = Prop.check(gen, Prop.Config(seed: some(15), runs: 200), &only_the_fixed_keys)
  try Test.assert(not result.ok?, "every key was one of the three")
  Test.assert(result.message.start_with?("falsified after "), result.message)
end
