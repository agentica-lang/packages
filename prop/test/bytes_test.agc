import Prop from "../prop"
import {Gen, Pair} from "../prop"

struct Frame
  tag: Int
  data: Bytes
end

private

def must(condition: Bool, text: String) -> Result[Void]
  return ok() if condition

  error(text)
end

def seeded(seed: Int) -> Prop.Config = Prop.Config(seed: some(seed), runs: 300)

def frame_text(frame: Frame) -> String = "#{frame.tag}:#{frame.data.to_a}"

# The names of a generator and a pair, bare, as a helper of a user writes them.
def tagged(gen: Gen[Bytes]) -> Gen[Pair[Int, Bytes]] = Prop.pair(Prop.int(0, 9), gen)

def test_bytes_stay_in_their_length_and_value_bounds() -> Result[Void]
  made = Prop.sample(Prop.bytes(2, 5), 1, 300)
  sizes = made.map do |b| b.length end
  try Test.eq(sizes.min, some(2))
  try Test.eq(sizes.max, some(5))
  values = made.map do |b| b.to_a.max.unwrap_or(0) end
  Test.assert(values.max.unwrap_or(0) > 200, "a byte never went above 200")
end

# A counterexample with `Bytes` is reported (as a list of values), where JSON.encode of `Bytes` does not compile.
def test_a_false_law_over_bytes_shrinks_to_the_fewest_zero_bytes() -> Result[Void]
  result = Prop.check(Prop.bytes(2, 12), seeded(3)) do |b| must(b.length < 4, "four bytes or more") end
  Test.assert(result.message.include?("shrunk to [0,0,0,0], seed 3:"), result.message)
end

def test_bytes_shrink_each_byte_toward_zero() -> Result[Void]
  result = Prop.check(Prop.bytes(1, 6), seeded(4)) do |b| must(b.at(0) < 100, "the first byte is 100 or more") end
  Test.assert(result.message.include?("shrunk to [100],"), result.message)
end

def test_a_struct_with_bytes_is_checked_through_map_shown() -> Result[Void]
  gen = Prop.map_shown(Prop.pair(Prop.int(0, 9), Prop.bytes(0, 6)), &frame_text) do |p|
    Frame(tag: p.first, data: p.second)
  end

  result = Prop.check(gen, seeded(5)) do |frame| must(frame.data.length < 3, "three bytes or more") end
  try Test.assert(result.message.include?("shrunk to 0:[0, 0, 0],"), result.message)
  Test.ok?(Prop.check(gen, seeded(6)) do |frame| must(frame.data.length <= 6, "too long") end)
end

def test_exhaustive_names_a_counterexample_of_bytes() -> Result[Void]
  result = Prop.exhaustive(Prop.bytes(0, 2), 1) do |b| must(b.length < 1, "not empty") end
  Test.assert(result.message.include?("counterexample [0]:"), result.message)
end

def test_bytes_pair_with_other_generators() -> Result[Void]
  result = Prop.check(tagged(Prop.bytes(1, 3)), seeded(7)) do |p| must(p.second.at(0) < 50, "50 or more") end
  Test.assert(result.message.include?("shrunk to {\"first\":0,\"second\":[50]},"), result.message)
end

def test_a_non_empty_list_is_never_empty_and_shrinks_to_one_item() -> Result[Void]
  gen = Prop.non_empty_list(Prop.int(1, 12), 8)
  lists = Prop.sample(gen, 1, 300)
  sizes = lists.map do |xs| xs.size end
  try Test.eq(sizes.min, some(1))
  try Test.eq(sizes.max, some(8))
  try Test.ok?(Prop.check(gen, seeded(8)) do |xs| must(not xs.empty?, "empty") end)
  result = Prop.check(gen, seeded(9)) do |xs| must(xs.all? do |x| x < 7 end, "an item is 7 or more") end
  Test.assert(result.message.include?("shrunk to [7],"), result.message)
end

# These laws fail on the empty list too, so a shrink tree that ignored the floor would end in `[]`.
def test_the_floor_of_a_list_holds_when_the_law_fails_on_the_empty_list() -> Result[Void]
  gen = Prop.non_empty_list(Prop.int(1, 12), 8)
  long = Prop.check(gen, seeded(9)) do |xs| must(xs.size <= 5, "long") end
  try Test.assert(long.message.include?("shrunk to [1,1,1,1,1,1],"), long.message)
  one = Prop.check(gen, seeded(11)) do |_| must(false, "always") end
  try Test.assert(one.message.include?("shrunk to [1],"), one.message)
  zeros = Prop.check(Prop.bytes(3, 10), seeded(12)) do |_| must(false, "always") end
  try Test.assert(zeros.message.include?("shrunk to [0,0,0],"), zeros.message)
  fewest = Prop.check(Prop.bytes(2, 12), seeded(13)) do |b| must(b.length < 6, "six bytes or more") end
  Test.assert(fewest.message.include?("shrunk to [0,0,0,0,0,0],"), fewest.message)
end

# `Prop.one_of` gives its items to JSON.encode, so fixed vectors of bytes go through an index and `map_shown`.
def test_vectors_of_bytes_are_drawn_through_an_index() -> Result[Void]
  vectors = ["ab".bytes, "".bytes, "xyz".bytes]
  gen = Prop.map_shown(Prop.int(0, vectors.size - 1), &vector_text) do |i| vectors.at(i) end
  result = Prop.check(gen, seeded(14)) do |b| must(b.length < 2, "two bytes or more") end
  Test.assert(result.message.include?("shrunk to bytes of 2,"), result.message)
end

def vector_text(bytes: Bytes) -> String = "bytes of #{bytes.length}"

# A cut of a sequence: the sizes of the pieces, none of them 0, cycled until the sequence is used up.
def test_any_cut_of_a_sequence_puts_it_back_together() -> Result[Void]
  Prop.check(Prop.pair(Prop.bytes(0, 40), Prop.non_empty_list(Prop.int(1, 12))), seeded(10)) do |p|
    pieces = cut(p.first, p.second)
    Prop.eq(Bytes.concat(pieces).to_a, p.first.to_a)
  end
end

def cut(whole: Bytes, sizes: List[Int]) -> List[Bytes]
  pieces: List[Bytes] = []
  rest = whole
  turn = 0
  while not rest.empty?
    size = sizes.at(turn % sizes.size)
    pieces = pieces.push(rest.take(size))
    rest = rest.drop(size)
    turn += 1
  end

  pieces
end
