import Prop from "pkg/prop/prop"
import Snappy from "../snappy"

private

def compressed(data: Bytes) -> Bytes = Snappy.compress(data)

def decompressed(block: Bytes) -> Result[Bytes] = Snappy.decompress(block)

def shown(data: Bytes) -> String = "#{data.to_a}"

# A run of a short piece, so that the compressor finds copies, some of them overlapping.
def run_of(pair: Prop.Pair[Bytes, Int]) -> Bytes = Bytes.concat(List.repeat(pair.first, pair.second))

# A valid block of the data, damaged in one of three ways: a byte changed, cut short, or a byte added.
def damaged(pair: Prop.Pair[Bytes, Int]) -> Bytes
  block = Snappy.compress(pair.first)
  at = pair.second % block.size
  if pair.second % 3 == 0
    block.slice(0, at)
  elsif pair.second % 3 == 1
    block.slice(0, at) + one_byte((block[at] + 1) % 256) + block.slice(at + 1, block.size - at - 1)
  else
    block + one_byte(at)
  end
end

def bytes_of(values: List[Int]) -> Bytes = Bytes.from_list(values).unwrap!

def one_byte(value: Int) -> Bytes = bytes_of([value])

def must(condition: Bool, text: String) -> Result[Void]
  return ok() if condition

  error(text)
end

# The bytes i % 251 for i below size: a literal that does not repeat within a copy's offset.
def pattern(size: Int) -> List[Int] = (0...size).map(->(i) { i % 251 })

# What the block of the test decodes to, computed one byte at a time: copies read the output as it is written.
def model(literal: List[Int]) -> List[Int]
  out: List[Int] = literal
  for _ in 0...20
    out = out.push(out[out.size - 4110])
  end

  for _ in 0...60
    out = out.push(out[out.size - 3])
  end

  for _ in 0...8
    out = out.push(out[out.size - 30])
  end

  out
end

# 5000 pseudo-random bytes from a linear congruential generator.
def period_bytes(size: Int) -> Bytes
  values: List[Int] = []
  state = 7
  for _ in 0...size
    state = (state * 1_103_515_245 + 12_345) % 2_147_483_648
    values = values.push(state.shift_right(16).bit_and(0xFF))
  end

  Bytes.from_list(values).unwrap!
end

def test_random_bytes_come_back_unchanged() -> Result[Void]
  Prop.roundtrip(Prop.bytes(0, 300), &compressed, Prop.Config(runs: 100), &decompressed)
end

def test_runs_of_a_short_piece_come_back_unchanged() -> Result[Void]
  runs = Prop.map_shown(Prop.pair(Prop.bytes(1, 6), Prop.int(1, 40)), &shown, &run_of)
  Prop.roundtrip(runs, &compressed, Prop.Config(runs: 100), &decompressed)
end

def test_a_damaged_block_is_ok_or_malformed() -> Result[Void]
  gen = Prop.map_shown(Prop.pair(Prop.bytes(1, 200), Prop.int(0, 300)), &shown, &damaged)
  Prop.check(gen, Prop.Config(runs: 100)) do |block|
    case decompressed(block)
      ok(_) -> ok()
      error(e) -> must(e.kind == "snappy.malformed", "kind #{e.kind}")
    end
  end
end

# The preamble says 8288. A literal of 8200 bytes fills two chunks, so the copies after it read chunks. Copy2 of 20 at
# offset 4110 reads bytes 4090 to 4109: it crosses from the first chunk into the second. Copy2 of 60 at offset 3
# overlaps. Copy1 of 8 at offset 30 reads from byte 8190 and crosses from the second chunk into the tail.
def test_copies_across_a_chunk_boundary_decode_as_the_model_says() -> Result[Void]
  literal = pattern(8200)
  block = bytes_of([0xE0, 0x40, 0xF4, 0x07, 0x20] + literal + [0x4E, 0x0E, 0x10, 0xEE, 0x03, 0x00, 0x11, 0x1E])
  case decompressed(block)
    ok(data) -> must(data == bytes_of(model(literal)), "a copy across the boundary differs from the model")
    error(e) -> error("decode failed: #{e.message}")
  end
end

def test_a_repeated_period_of_5000_bytes_round_trips() -> Result[Void]
  period = period_bytes(5000)
  data = period + period + period
  case decompressed(compressed(data))
    ok(back) -> must(back == data, "the 15000 bytes do not come back")
    error(e) -> error("decode failed: #{e.message}")
  end
end
