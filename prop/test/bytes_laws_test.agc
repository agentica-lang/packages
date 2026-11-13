import Prop from "../prop"

private

def seeded(seed: Int) -> Prop.Config = Prop.Config(seed: some(seed), runs: 100)

def hex(bytes: Bytes) -> String = bytes.to_a.map(->(b) { b.to_s }).join(",")

def unhex(text: String) -> Result[Bytes]
  return ok("".bytes) if text == ""

  numbers = text.split(",").map(->(part) { part.to_i.unwrap_or(0) })
  Bytes.from_list(numbers)
end

def join(a: Bytes, b: Bytes) -> Bytes = Bytes.concat([a, b])

def first_three(bytes: Bytes) -> Bytes = bytes.take(3)

def slow_length(bytes: Bytes) -> Int = bytes.to_a.size

def without_last(bytes: Bytes) -> Bytes = bytes.take(bytes.length - 1)

def test_a_round_trip_over_bytes() -> Result[Void] = Prop.roundtrip(Prop.bytes(0, 12), &hex, &unhex)

def test_a_broken_round_trip_over_bytes_names_the_bytes() -> Result[Void]
  result = Prop.roundtrip(Prop.bytes(1, 6), &without_last) do |kept| ok(kept) end
  try Test.assert(result.message.include?("decode(encode(x)) differs from x"), result.message)
  try Test.assert(result.message.include?("shrunk to [0],"), result.message)
  Test.assert(result.message.include?("expected [0], got []"), result.message)
end

def test_idempotent_over_bytes() -> Result[Void] = Prop.idempotent(Prop.bytes(0, 12), &first_three)

def test_associative_over_bytes_and_a_counterexample_of_bytes() -> Result[Void]
  try Prop.associative(Prop.bytes(0, 6), &join)
  result = Prop.associative(Prop.bytes(0, 6), seeded(2)) do |a, b| Bytes.concat([a.take(1), b]) end
  try Test.assert(not result.ok?, "a law that groups differently held")
  Test.assert(result.message.include?("\"a\":["), result.message)
end

def test_commutative_over_bytes_fails_with_the_pair_of_bytes() -> Result[Void]
  result = Prop.commutative(Prop.bytes(1, 4), seeded(3), &join)
  try Test.assert(result.message.include?("op(a, b) differs from op(b, a)"), result.message)
  Test.assert(result.message.include?("shrunk to {\"a\":[0],\"b\":[1]},"), result.message)
end

def test_oracle_and_preserves_take_bytes_as_input() -> Result[Void]
  try Prop.oracle(Prop.bytes(0, 12), ->(bytes: Bytes) { bytes.length }, &slow_length)
  Prop.preserves(Prop.bytes(0, 12), &first_three) do |bytes| bytes.length.clamp(0, 3) end
end
