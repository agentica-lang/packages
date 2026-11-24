import Binary from "std/binary"
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

# One byte of a fixture changed. `body_only` keeps the magic and the footer, so the damage lands in the pages.
def damaged(name: String, change: Prop.Pair[Int, Int], body_only: Bool) -> Bytes
  data = fixture(name)
  span = data.size
  start = 0
  if body_only
    footer = Binary.read_u32_le(data, data.size - 8).unwrap!
    start = 4
    span = data.size - 8 - footer - 4
  end

  at = start + change.first % span
  data.slice(0, at) + Bytes.from_list([change.second]).unwrap! + data.slice(at + 1, data.size - at - 1)
end

def shown(data: Bytes) -> String = "#{data.size} bytes, #{data.to_a}"

def changes() -> Prop.Gen[Prop.Pair[Int, Int]] = Prop.pair(Prop.int(0, 1000000), Prop.int(0, 255))

def pages_of(name: String) -> Result[Void]
  in_pages = Prop.map_shown(changes(), &shown, ->(change) { damaged(name, change, true) })
  Prop.check(in_pages, Prop.Config(runs: 20), &outcome)
end

def test_random_bytes_are_read_or_refused() -> Result[Void]
  Prop.check(Prop.bytes(0, 300), Prop.Config(runs: 100), &outcome)
end

def test_a_damaged_fixture_is_read_or_refused() -> Result[Void]
  anywhere = Prop.map_shown(changes(), &shown, ->(change) { damaged("nulls_snappy", change, false) })
  Prop.check(anywhere, Prop.Config(runs: 25), &outcome)
end

def test_damaged_dictionary_pages_are_read_or_refused() -> Result[Void] = pages_of("kinds_dictionary_snappy")

def test_damaged_gzip_pages_are_read_or_refused() -> Result[Void] = pages_of("nulls_gzip")

def test_damaged_v2_pages_are_read_or_refused() -> Result[Void] = pages_of("nulls_v2_snappy")

def test_damaged_byte_array_pages_are_read_or_refused() -> Result[Void] = pages_of("nulls_plain")
