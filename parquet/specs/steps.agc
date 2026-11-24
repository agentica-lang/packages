## The steps of the features. The fixtures are the files of specs/fixtures, written with pyarrow by make_fixtures.py; the
## hybrid encodings come from rle_peer.py, an independent encoder. Each step compares what the package reads with what the
## fixture or the peer says.

import BDD from "std/bdd"
import Parquet from "../parquet"
import Rle from "../src/rle"
import Values from "../src/values"

def main() -> Void
  BDD.run([
    BDD.step("the rows of the fixture {string} are the expected rows", &rows_match),
    BDD.step("the schema of the fixture {string} is:", &schema_is),
    BDD.step("the row count of the fixture {string} is {int}", &row_count_is),
    BDD.step("the column {string} of the fixture {string} keeps NaN and the infinities", &special_column),
    BDD.step("the fixture {string} is refused as {string}", &refused_as),
    BDD.step("the fixture {string} keeping its first {int} bytes is refused as {string}", &prefix_refused),
    BDD.step(
      "the fixture {string} with the byte {int} from its end set to {int} is refused as {string}",
      &byte_refused,
    ),
    BDD.step("the fixture {string} missing its last {int} bytes is refused as {string}", &missing_refused),
    BDD.step("the column {string} of the fixture {string} has texts of {int} bytes each, {int} of them", &big_texts),
    BDD.step("reading {int} rows of the fixture {string} gives {int} rows", &limit_gives),
    BDD.step("reading the column {string} of the fixture {string} is refused as {string}", &column_refused),
    BDD.step("reading {int} rows of the fixture {string} is refused as {string}", &limit_refused),
    BDD.step(
      "the hybrid decoder reads back the peer's {int} values from the seed {int} at width {int}",
      &hybrid_reads,
    ),
    BDD.step(
      "the hybrid decoder refuses the peer's {int} values from the seed {int} at width {int} keeping its first {int} bytes",
      &hybrid_refuses,
    ),
  ])
end

private

PEER = "specs/fixtures/rle_peer.py"
PEER_MS = 60_000
MAX_FILE = 1048576
MALFORMED = "parquet.malformed"
INF = Float.from_bits(9218868437227405312)
NEG_INF = Float.from_bits(-4503599627370496)

def run_peer(args: List[String]) -> String
  process = Process.spawn_captured("python3", ["-I", PEER] + args, Process.Options(timeout_ms: PEER_MS)).unwrap!
  output = Process.output(process, PEER_MS).unwrap!
  _ = Process.wait(process, PEER_MS)
  output.stdout
end

def fixture_bytes(name: String) -> Result[Bytes]
  handle = try File.open("specs/fixtures/#{name}.parquet")
  File.read_bytes(handle, MAX_FILE)
end

def read_rows(data: Bytes) -> Result[List[Map[String, JSON.Value]]]
  file = try Parquet.open(data)
  Parquet.rows(file)
end

def read_fixture(name: String) -> Result[List[Map[String, JSON.Value]]]
  data = try fixture_bytes(name)
  read_rows(data)
end

def refused(ctx: BDD.Context, data: Bytes, kind: String) -> BDD.Context
  case read_rows(data)
    ok(_) -> BDD.assert(ctx, false, "a damaged file was read")
    error(e) -> BDD.assert(ctx, e.kind == kind, "gave kind #{e.kind}, not #{kind}")
  end
end

def rows_match(ctx: BDD.Context, args: List[String]) -> BDD.Context
  expected = JSON.parse(File.read_text("specs/fixtures/#{args[0]}.json").unwrap!).unwrap!
  want = JSON.get(expected, "rows").unwrap!
  case read_fixture(args[0])
    ok(rows) -> BDD.assert(ctx, JSON.from(rows) == want, "#{args[0]} reads other rows")
    error(e) -> BDD.assert(ctx, false, "#{args[0]} gave #{e.kind}: #{e.message}")
  end
end

def schema_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  file = Parquet.open(fixture_bytes(args[0]).unwrap!).unwrap!
  got = Parquet.schema(file).map { |field| "#{field.name}|#{kind_text(field.kind)}|#{field.nullable}" }
  want = BDD.table(ctx).drop(1).map { |row| "#{row[0]}|#{row[1]}|#{row[2]}" }
  BDD.assert(ctx, got == want, "the schema is #{got}")
end

def kind_text(kind: Parquet.Kind) -> String
  case kind
    Parquet.Kind.Boolean -> "Boolean"
    Parquet.Kind.Int32 -> "Int32"
    Parquet.Kind.Int64 -> "Int64"
    Parquet.Kind.Float -> "Float"
    Parquet.Kind.Double -> "Double"
    Parquet.Kind.String -> "String"
    Parquet.Kind.Binary -> "Binary"
    Parquet.Kind.FixedBinary(size) -> "FixedBinary(#{size})"
  end
end

def row_count_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  file = Parquet.open(fixture_bytes(args[0]).unwrap!).unwrap!
  BDD.assert(ctx, Parquet.row_count(file) == args[1].to_i!, "the row count is #{Parquet.row_count(file)}")
end

def exact(x: Optional[Float], want: Float) -> Bool
  case x
    some(v) -> v == want
    none -> false
  end
end

def nan_at(x: Optional[Float]) -> Bool
  case x
    some(v) -> v != v
    none -> false
  end
end

def null_at(x: Optional[Float]) -> Bool
  case x
    some(_) -> false
    none -> true
  end
end

def special_column(ctx: BDD.Context, args: List[String]) -> BDD.Context
  file = Parquet.open(fixture_bytes(args[1]).unwrap!).unwrap!
  case Parquet.column(file, args[0])
    ok(Values.Values.Floats(xs)) ->
      kept = xs.size == 5 and nan_at(xs[0]) and exact(xs[1], INF) and exact(xs[2], NEG_INF) and exact(xs[3], 0.0)
      BDD.assert(ctx, kept and null_at(xs[4]), "the column lost a special value")
    ok(_) -> BDD.assert(ctx, false, "the column is not floats")
    error(e) -> BDD.assert(ctx, false, "gave kind #{e.kind}")
  end
end

def refused_as(ctx: BDD.Context, args: List[String]) -> BDD.Context
  case read_fixture(args[0])
    ok(_) -> BDD.assert(ctx, false, "#{args[0]} was read")
    error(e) -> BDD.assert(ctx, e.kind == args[1], "#{args[0]} gave kind #{e.kind}")
  end
end

def prefix_refused(ctx: BDD.Context, args: List[String]) -> BDD.Context
  data = fixture_bytes(args[0]).unwrap!
  refused(ctx, data.slice(0, args[1].to_i!), args[2])
end

def byte_refused(ctx: BDD.Context, args: List[String]) -> BDD.Context
  data = fixture_bytes(args[0]).unwrap!
  at = data.size - args[1].to_i!
  changed = Bytes.from_list([args[2].to_i!]).unwrap!
  refused(ctx, data.slice(0, at) + changed + data.slice(at + 1, data.size - at - 1), args[3])
end

def missing_refused(ctx: BDD.Context, args: List[String]) -> BDD.Context
  data = fixture_bytes(args[0]).unwrap!
  refused(ctx, data.slice(0, data.size - args[1].to_i!), args[2])
end

def limit_gives(ctx: BDD.Context, args: List[String]) -> BDD.Context
  file = Parquet.open(fixture_bytes(args[1]).unwrap!).unwrap!
  case Parquet.rows(file, some(args[0].to_i!))
    ok(rows) -> BDD.assert(ctx, rows.size == args[2].to_i!, "got #{rows.size} rows")
    error(e) -> BDD.assert(ctx, false, "gave kind #{e.kind}")
  end
end

def big_texts(ctx: BDD.Context, args: List[String]) -> BDD.Context
  file = Parquet.open(fixture_bytes(args[1]).unwrap!).unwrap!
  case Parquet.column(file, args[0])
    ok(Values.Values.Texts(xs)) ->
      sizes = xs.map { |x| text_size(x) }
      want = (0...args[3].to_i!).map(->(_i) { args[2].to_i! })
      BDD.assert(ctx, sizes == want, "the sizes are #{sizes}")
    ok(_) -> BDD.assert(ctx, false, "the column is not texts")
    error(e) -> BDD.assert(ctx, false, "gave #{e.kind}: #{e.message}")
  end
end

def text_size(x: Optional[String]) -> Int
  case x
    some(s) -> s.bytes.size
    none -> -1
  end
end

def kind_is(ctx: BDD.Context, result: Result[Values.Values], kind: String) -> BDD.Context
  case result
    ok(_) -> BDD.assert(ctx, false, "the request was served")
    error(e) -> BDD.assert(ctx, e.kind == kind, "gave kind #{e.kind}")
  end
end

def column_refused(ctx: BDD.Context, args: List[String]) -> BDD.Context
  file = Parquet.open(fixture_bytes(args[1]).unwrap!).unwrap!
  kind_is(ctx, Parquet.column(file, args[0]), args[2])
end

def limit_refused(ctx: BDD.Context, args: List[String]) -> BDD.Context
  file = Parquet.open(fixture_bytes(args[1]).unwrap!).unwrap!
  kind_is(ctx, Parquet.column(file, "n", some(args[0].to_i!)), args[2])
end

def strings_of(values: List[Int]) -> List[String] = values.map { |v| "#{v}" }

def hybrid_reads(ctx: BDD.Context, args: List[String]) -> BDD.Context
  lines = run_peer(["#{args[1]}", "#{args[2]}", "#{args[0]}"]).split("\n")
  data = OpenSSL.Digest.hexdecode(lines[0]).unwrap!
  want = lines[1].split(",")
  case Rle.decode(data, args[2].to_i!, args[0].to_i!)
    ok(values) -> BDD.assert(ctx, strings_of(values) == want, "the decoder read other values")
    error(e) -> BDD.assert(ctx, false, "the decoder gave kind #{e.kind}")
  end
end

def hybrid_refuses(ctx: BDD.Context, args: List[String]) -> BDD.Context
  lines = run_peer(["#{args[1]}", "#{args[2]}", "#{args[0]}"]).split("\n")
  data = OpenSSL.Digest.hexdecode(lines[0]).unwrap!
  case Rle.decode(data.slice(0, args[3].to_i!), args[2].to_i!, args[0].to_i!)
    ok(_) -> BDD.assert(ctx, false, "a cut encoding was read")
    error(e) -> BDD.assert(ctx, e.kind == MALFORMED, "gave kind #{e.kind}")
  end
end
