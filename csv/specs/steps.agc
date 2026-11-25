## The steps of the features. The peer is `fixtures/csv_peer.py` (Python's `csv` module); the fixed cases are RFC 4180.

import BDD from "std/bdd"
import Csv from "../csv"

def main() -> Void
  BDD.run([
    BDD.step("csv reads these texts:", &reads),
    BDD.step("csv reads these texts with the separator {string}:", &reads_with),
    BDD.step("csv refuses these texts as {string}:", &refuses),
    BDD.step("csv writes these rows:", &writes),
    BDD.step("csv writes these rows with the separator {string}:", &writes_with),
    BDD.step("csv refuses these separators:", &refuses_separators),
    BDD.step("csv reads these texts as maps:", &reads_maps),
    BDD.step("csv refuses these texts as maps:", &refuses_maps),
    BDD.step("csv writes these maps:", &writes_maps),
    BDD.step(
      "the peer's {int} tables from the seed {int} with the separator {string} read and write as the peer says",
      &as_peer_says,
    ),
  ])
end

private

PEER = "specs/fixtures/csv_peer.py"
PEER_MS = 60_000
MALFORMED = "csv.malformed"
INVALID = "csv.invalid"

# The marks of the features: a table cell cannot hold a CR, a tab or a backslash escape.
MARKS = [
  ["{CRLF}", "\r\n", "\\r\\n"],
  ["{CR}", "\r", "\\r"],
  ["{LF}", "\n", "\\n"],
  ["{TAB}", "\t", "\\t"],
  ["{Q}", "\"", "\\\""],
]

struct Table
  rows: List[List[String]]
end

struct Maps
  rows: List[Map[String, String]]
end

# A text or a separator as the feature writes it.
def unescaped(cell: String) -> String
  text = cell.replace("{BOM}", String.from_code(65279))
  for mark in MARKS
    text = text.replace(mark[0], mark[1])
  end

  text
end

# Rows or maps as JSON text: the same marks, as JSON escapes.
def json_text(cell: String) -> String
  text = cell
  for mark in MARKS
    text = text.replace(mark[0], mark[2])
  end

  text.replace("{BOM}", "\\ufeff")
end

def rows_of(json: String) -> List[List[String]] = JSON.decode("{\"rows\": #{json_text(json)}}", Table).unwrap!.rows

def maps_of(json: String) -> List[Map[String, String]]
  JSON.decode("{\"rows\": #{json_text(json)}}", Maps).unwrap!.rows
end

def body(ctx: BDD.Context) -> List[List[String]] = BDD.table(ctx).drop(1)

def run_peer(args: List[String]) -> String
  process = Process.spawn_captured("python3", ["-I", PEER] + args, Process.Options(timeout_ms: PEER_MS)).unwrap!
  output = Process.output(process, PEER_MS).unwrap!
  _ = Process.wait(process, PEER_MS)
  output.stdout
end

def read_all(ctx: BDD.Context, separator: String) -> BDD.Context
  checked = ctx
  for row in body(ctx)
    text = unescaped(row[0])
    case Csv.parse(text, separator)
      ok(rows) -> checked = BDD.assert(checked, rows == rows_of(row[1]), "#{row[0]} reads #{rows}")
      error(e) -> checked = BDD.assert(checked, false, "#{row[0]} gave #{e.kind}: #{e.message}")
    end
  end

  checked
end

def reads(ctx: BDD.Context, args: List[String]) -> BDD.Context = read_all(ctx, ",")

def reads_with(ctx: BDD.Context, args: List[String]) -> BDD.Context = read_all(ctx, unescaped(args[0]))

def refuses(ctx: BDD.Context, args: List[String]) -> BDD.Context
  checked = ctx
  for row in body(ctx)
    case Csv.parse(unescaped(row[0]))
      ok(rows) -> checked = BDD.assert(checked, false, "#{row[0]} was read as #{rows}")
      error(e) ->
        named = e.message.include?("line #{row[1]}")
        checked = BDD.assert(checked, e.kind == args[0] and named, "#{row[0]} gave #{e.kind}: #{e.message}")
    end
  end

  checked
end

def write_all(ctx: BDD.Context, separator: String) -> BDD.Context
  checked = ctx
  for row in body(ctx)
    case Csv.encode(rows_of(row[0]), separator)
      ok(text) -> checked = BDD.assert(checked, text == unescaped(row[1]), "#{row[0]} writes #{text}")
      error(e) -> checked = BDD.assert(checked, false, "#{row[0]} gave #{e.kind}")
    end
  end

  checked
end

def writes(ctx: BDD.Context, args: List[String]) -> BDD.Context = write_all(ctx, ",")

def writes_with(ctx: BDD.Context, args: List[String]) -> BDD.Context = write_all(ctx, unescaped(args[0]))

def refuses_separators(ctx: BDD.Context, args: List[String]) -> BDD.Context
  checked = ctx
  for row in body(ctx)
    case Csv.parse("a", unescaped(row[0]))
      ok(_) -> checked = BDD.assert(checked, false, "the separator #{row[0]} was accepted")
      error(e) -> checked = BDD.assert(checked, e.kind == INVALID, "gave #{e.kind}")
    end
  end

  checked
end

def reads_maps(ctx: BDD.Context, args: List[String]) -> BDD.Context
  checked = ctx
  for row in body(ctx)
    case Csv.parse_maps(unescaped(row[0]))
      ok(maps) -> checked = BDD.assert(checked, maps == maps_of(row[1]), "#{row[0]} read #{maps}")
      error(e) -> checked = BDD.assert(checked, false, "#{row[0]} gave #{e.kind}: #{e.message}")
    end
  end

  checked
end

def refuses_maps(ctx: BDD.Context, args: List[String]) -> BDD.Context
  checked = ctx
  for row in body(ctx)
    case Csv.parse_maps(unescaped(row[0]))
      ok(_) -> checked = BDD.assert(checked, false, "#{row[0]} was read")
      error(e) -> checked = BDD.assert(checked, e.kind == row[1], "#{row[0]} gave #{e.kind}")
    end
  end

  checked
end

def writes_maps(ctx: BDD.Context, args: List[String]) -> BDD.Context
  checked = ctx
  for row in body(ctx)
    case Csv.encode_maps(row[0].split(","), maps_of(row[1]))
      ok(text) -> checked = BDD.assert(checked, text == unescaped(row[2]), "wrote #{text}")
      error(e) -> checked = BDD.assert(checked, false, "gave #{e.kind}")
    end
  end

  checked
end

def as_peer_says(ctx: BDD.Context, args: List[String]) -> BDD.Context
  separator = unescaped(args[2])
  lines = run_peer(["#{args[1]}", "#{args[0]}", separator]).split("\n")
  checked = BDD.assert(ctx, lines.size == args[0].to_i! * 2 + 1, "the peer wrote #{lines.size} lines")
  for index in 0...args[0].to_i!
    text = String.from_bytes(OpenSSL.Digest.hexdecode(lines[index * 2]).unwrap!).unwrap!
    rows = rows_of(lines[index * 2 + 1])
    checked = BDD.assert(checked, Csv.parse(text, separator) == ok(rows), "table #{index} reads another way")
    checked = BDD.assert(checked, Csv.encode(rows, separator) == ok(text), "table #{index} writes another way")
  end

  checked
end
