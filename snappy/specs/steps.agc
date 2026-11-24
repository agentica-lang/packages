## The steps of the features. The peer is `fixtures/snappy_peer.py`, which writes blocks and their data, damages them,
## and decodes the blocks that the codec writes; each step checks what the codec says against what the peer says.

import BDD from "std/bdd"
import Snappy from "../snappy"

def main() -> Void
  BDD.run([
    BDD.step("the codec reads these blocks:", &reads_fixed),
    BDD.step("the codec refuses these blocks:", &refuses_fixed),
    BDD.step("the peer writes {int} blocks from the seed {int}", &valid_blocks),
    BDD.step("the peer writes {int} damaged blocks from the seed {int}", &damaged_blocks),
    BDD.step("the codec reads every block as the peer says", &reads_as_peer_says),
    BDD.step("the codec gives the same outcome as the peer for every damaged block", &agrees_on_damaged),
    BDD.step("the codec compresses the peer's data and the peer decodes it back", &compresses_blocks),
    BDD.step("the codec compresses these inputs and the peer decodes them to the same bytes:", &compresses_inputs),
  ])
end

private

PEER = "specs/fixtures/snappy_peer.py"
LINES = "lines"
PEER_MS = 60_000
MALFORMED = "snappy.malformed"

def run_peer(args: List[String], input: String) -> String
  process = Process.spawn_captured("python3", ["-I", PEER] + args, Process.Options(timeout_ms: PEER_MS)).unwrap!
  if input != ""
    _ = Process.send(process, input, PEER_MS)
    _ = Process.close_stdin(process, PEER_MS)
  end

  output = Process.output(process, PEER_MS).unwrap!
  _ = Process.wait(process, PEER_MS)
  output.stdout
end

def keep_lines(ctx: BDD.Context, mode: String, seed: Int, count: Int) -> BDD.Context
  lines = run_peer([mode, "#{seed}", "#{count}"], "").split("\n").select { |line| line != "" }
  BDD.assert(BDD.set(ctx, LINES, JSON.from(lines)), lines.size == count, "the peer wrote #{lines.size} lines")
end

def lines_of(ctx: BDD.Context) -> List[String]
  rows = JSON.list(BDD.get(ctx, LINES).unwrap!).unwrap!
  rows.map { |row| JSON.string(row).unwrap! }
end

def valid_blocks(ctx: BDD.Context, args: List[String]) -> BDD.Context
  keep_lines(ctx, "valid", args[1].to_i!, args[0].to_i!)
end

def damaged_blocks(ctx: BDD.Context, args: List[String]) -> BDD.Context
  keep_lines(ctx, "damaged", args[1].to_i!, args[0].to_i!)
end

def reads_fixed(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  for row in BDD.table(ctx).drop(1)
    case Snappy.decompress(bytes_of(row[0]))
      ok(data) -> return BDD.assert(ctx, false, "#{row[0]} gave #{text_of(data)}") if text_of(data) != row[1]
      error(e) -> return BDD.assert(ctx, false, "#{row[0]} gave #{e.message}")
    end
  end

  BDD.assert(ctx, BDD.table(ctx).size > 1, "no blocks to check")
end

def refuses_fixed(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  for row in BDD.table(ctx).drop(1)
    case Snappy.decompress(bytes_of(row[0]))
      ok(data) -> return BDD.assert(ctx, false, "#{row[0]} gave #{text_of(data)}")
      error(e) -> return BDD.assert(ctx, false, "#{row[0]} gave kind #{e.kind}") if e.kind != MALFORMED
    end
  end

  BDD.assert(ctx, BDD.table(ctx).size > 1, "no blocks to check")
end

def reads_as_peer_says(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  lines = lines_of(ctx)
  for line in lines
    parts = line.split("\t")
    case Snappy.decompress(bytes_of(parts[0]))
      ok(data) ->
        got = hex_of(data)
        return BDD.assert(ctx, false, "#{parts[0]} gave #{got}, the peer #{parts[1]}") if got != parts[1]
      error(e) -> return BDD.assert(ctx, false, "#{parts[0]} gave #{e.message}, the peer #{parts[1]}")
    end
  end

  BDD.assert(ctx, lines.size > 0, "no blocks to check")
end

def agrees_on_damaged(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  accepted = 0
  refused = 0
  lines = lines_of(ctx)
  for line in lines
    parts = line.split("\t")
    seen = outcome(Snappy.decompress(bytes_of(parts[0])))
    return BDD.assert(ctx, false, "#{parts[0]}: the codec says #{seen}, the peer #{parts[1]}") if seen != parts[1]

    if seen == "error"
      refused += 1
    else
      accepted += 1
    end
  end

  BDD.assert(ctx, accepted > 0 and refused > 0, "all accepted or all refused: #{accepted}, #{refused}")
end

def compresses_blocks(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  rows = lines_of(ctx).map { |line| line.split("\t") }
  blocks = rows.map { |parts| hex_of(Snappy.compress(bytes_of(parts[1]))) }
  peer_decodes(ctx, blocks, rows.map { |parts| parts[1] })
end

def compresses_inputs(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  blocks: List[String] = []
  expected: List[String] = []
  for row in BDD.table(ctx).drop(1)
    source = bytes_of(run_peer(["noise", row[2], row[0]], ""))
    input = source + source.take(row[1].to_i!)
    compressed = Snappy.compress(input)
    case Snappy.decompress(compressed)
      ok(back) -> return BDD.assert(ctx, false, "#{input.size} bytes do not round trip") if back != input
      error(e) -> return BDD.assert(ctx, false, "#{input.size} bytes gave #{e.message}")
    end

    blocks = blocks.push(hex_of(compressed))
    expected = expected.push(hex_of(input))
  end

  peer_decodes(ctx, blocks, expected)
end

# The peer decodes each block, and its answer for block i must be the hex of the data `expected[i]`.
def peer_decodes(ctx: BDD.Context, blocks: List[String], expected: List[String]) -> BDD.Context
  replies = run_peer(["decode"], blocks.join("\n")).split("\n")
  if replies.size != blocks.size
    return BDD.assert(ctx, false, "the peer answered #{replies.size} of #{blocks.size} blocks")
  end

  for i in 0...blocks.size
    got = replies[i]
    return BDD.assert(ctx, false, "#{blocks[i]}: the peer says #{got}, not #{expected[i]}") if got != expected[i]
  end

  BDD.assert(ctx, blocks.size > 0, "no blocks to check")
end

def outcome(decoded: Result[Bytes]) -> String
  case decoded
    ok(data) -> hex_of(data)
    error(_) -> "error"
  end
end

def bytes_of(text: String) -> Bytes
  return "".bytes if text == "-" or text == ""
  OpenSSL.Digest.hexdecode(text).unwrap!
end

def hex_of(data: Bytes) -> String = OpenSSL.Digest.hexencode(data)

# A table writes empty data as `-`.
def text_of(data: Bytes) -> String
  return "-" if data.size == 0

  hex_of(data)
end
