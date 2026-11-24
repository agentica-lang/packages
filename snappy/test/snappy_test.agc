import Prop from "pkg/prop/prop"
import Snappy from "../snappy"

private

def compressed(data: Bytes) -> Bytes = Snappy.compress(data)

def decompressed(block: Bytes) -> Result[Bytes] = Snappy.decompress(block)

def shown(data: Bytes) -> String = "#{data.to_a}"

# A run of a short piece, so that the compressor finds copies, some of them overlapping.
def run_of(pair: Prop.Pair[Bytes, Int]) -> Bytes = Bytes.concat(List.repeat(pair.first, pair.second))

def must(condition: Bool, text: String) -> Result[Void]
  return ok() if condition

  error(text)
end

def test_random_bytes_come_back_unchanged() -> Result[Void]
  Prop.roundtrip(Prop.bytes(0, 300), &compressed, Prop.Config(runs: 100), &decompressed)
end

def test_runs_of_a_short_piece_come_back_unchanged() -> Result[Void]
  runs = Prop.map_shown(Prop.pair(Prop.bytes(1, 6), Prop.int(1, 40)), &shown, &run_of)
  Prop.roundtrip(runs, &compressed, Prop.Config(runs: 100), &decompressed)
end

def test_a_refused_block_is_always_malformed() -> Result[Void]
  Prop.check(Prop.bytes(0, 64), Prop.Config(runs: 100)) do |block|
    case decompressed(block)
      ok(_) -> ok()
      error(e) -> must(e.kind == "snappy.malformed", "kind #{e.kind}")
    end
  end
end
