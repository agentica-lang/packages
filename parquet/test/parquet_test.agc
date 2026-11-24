import Prop from "pkg/prop/prop"
import Parquet from "../parquet"

private

MAX_FILE = 1048576

def fixture(name: String) -> Bytes
  handle = File.open("specs/fixtures/#{name}.parquet").unwrap!
  File.read_bytes(handle, MAX_FILE).unwrap!
end

def must(condition: Bool, text: String) -> Result[Void]
  return ok() if condition

  error(text)
end

def read_all(data: Bytes) -> Result[List[Map[String, JSON.Value]]]
  file = try Parquet.open(data)
  Parquet.rows(file)
end

# Every byte string is read or refused, and a refusal is one of this package's two error kinds.
def outcome(data: Bytes) -> Result[Void]
  case read_all(data)
    ok(_) -> ok()
    error(e) -> must(e.kind == "parquet.malformed" or e.kind == "parquet.unsupported", "refused as #{e.kind}")
  end
end

def damaged(pair: Prop.Pair[Int, Int]) -> Bytes
  data = fixture("nulls_snappy")
  at = pair.first % data.size
  data.slice(0, at) + Bytes.from_list([pair.second]).unwrap! + data.slice(at + 1, data.size - at - 1)
end

def shown(data: Bytes) -> String = "#{data.size} bytes, #{data.to_a}"

def test_random_bytes_are_read_or_refused() -> Result[Void]
  Prop.check(Prop.bytes(0, 300), Prop.Config(runs: 100), &outcome)
end

def test_a_damaged_fixture_is_read_or_refused() -> Result[Void]
  changed = Prop.map_shown(Prop.pair(Prop.int(0, 100000), Prop.int(0, 255)), &shown, &damaged)
  Prop.check(changed, Prop.Config(runs: 25), &outcome)
end
