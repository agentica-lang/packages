## The steps of the features. The peer is `fixtures/zstd_peer.py`, which drives the reference `zstd` command line: it
## writes frames and the data they hold, and says what `zstd -d` makes of damaged ones. The codec runs in `driver.agc`,
## a process of its own, so that a step is not held to the step budget of a scenario; each step checks what the codec
## says against what the peer says.

import BDD from "std/bdd"

def main() -> Void
  BDD.run([
    BDD.step("the peer writes {int} frames from the seed {int}", &valid_frames),
    BDD.step("the peer writes {int} multi-frame inputs from the seed {int}", &multi_frames),
    BDD.step("the peer writes {int} damaged frames from the seed {int}", &damaged_frames),
    BDD.step("the peer writes {int} columnar frames from the seed {int}", &columnar_frames),
    BDD.step("the peer writes {int} single-segment frames from the seed {int}", &arrow_frames),
    BDD.step("the codec reads every frame at exactly its size and refuses it one byte short", &reads_at_its_size),
    BDD.step("the reference tool is shown", &shows_version),
    BDD.step("the codec reads every frame as the peer says", &reads_as_peer_says),
    BDD.step("the codec refuses what the peer refuses and reads what the peer reads", &agrees_on_damaged),
    BDD.step("the peer writes {int} hand-made frames from the seed {int}", &hand_made_frames),
    BDD.step("the peer writes {int} frames with a checksum from the seed {int}", &checked_frames),
    BDD.step("the codec refuses the frame cut at every length", &cut_everywhere),
    BDD.step("the codec gives the data or an error for the frame with every bit flipped in turn", &flipped_everywhere),
  ])
end

private

PEER = "specs/fixtures/zstd_peer.py"
DRIVER = "specs/driver.agc"
LINES = "lines"
PEER_MS = 300_000
DRIVER_MS = 300_000
LIMIT = 100_000_000
MALFORMED = "zstd.malformed"
KINDS = ["zstd.malformed", "zstd.unsupported"]

def run_peer(args: List[String]) -> String
  process = Process.spawn_captured("python3", ["-I", PEER] + args, Process.Options(timeout_ms: PEER_MS)).unwrap!
  output = Process.output(process, PEER_MS).unwrap!
  _ = Process.wait(process, PEER_MS)
  output.stdout
end

# One answer line for each request line.
def drive(requests: List[String]) -> List[String]
  process = Process.spawn_captured("agentica", [DRIVER], Process.Options(timeout_ms: DRIVER_MS)).unwrap!
  for request in requests
    _ = Process.send(process, request + "\n", DRIVER_MS)
  end

  _ = Process.close_stdin(process, DRIVER_MS)
  output = Process.output(process, DRIVER_MS).unwrap!
  _ = Process.wait(process, DRIVER_MS)
  output.stdout.split("\n").select { |line| line != "" }
end

def keep_lines(ctx: BDD.Context, mode: String, seed: Int, count: Int) -> BDD.Context
  lines = run_peer([mode, "#{seed}", "#{count}"]).split("\n").select { |line| line != "" }
  BDD.assert(BDD.set(ctx, LINES, JSON.from(lines)), lines.size == count, "the peer wrote #{lines.size} lines")
end

def lines_of(ctx: BDD.Context) -> List[String]
  rows = JSON.list(BDD.get(ctx, LINES).unwrap!).unwrap!
  rows.map { |row| JSON.string(row).unwrap! }
end

def valid_frames(ctx: BDD.Context, args: List[String]) -> BDD.Context
  keep_lines(ctx, "valid", args[1].to_i!, args[0].to_i!)
end

def multi_frames(ctx: BDD.Context, args: List[String]) -> BDD.Context
  keep_lines(ctx, "multi", args[1].to_i!, args[0].to_i!)
end

def hand_made_frames(ctx: BDD.Context, args: List[String]) -> BDD.Context
  keep_lines(ctx, "hand-made", args[1].to_i!, args[0].to_i!)
end

def columnar_frames(ctx: BDD.Context, args: List[String]) -> BDD.Context
  keep_lines(ctx, "columnar", args[1].to_i!, args[0].to_i!)
end

def arrow_frames(ctx: BDD.Context, args: List[String]) -> BDD.Context
  keep_lines(ctx, "arrow", args[1].to_i!, args[0].to_i!)
end

# The reference tool may differ from a CI runner to another: its version is part of what a failure needs.
def shows_version(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  version = run_peer(["version"]).strip
  IO.puts("reference tool: #{version}")
  BDD.assert(ctx, version.start_with?("*** Zstandard CLI") or version.include?("zstd"), "no zstd version: #{version}")
end

# A frame with its content size and no checksum, as an Arrow writer makes it, is read when the limit is exactly the
# size of its content, and is `zstd.too_large` with one byte less.
def reads_at_its_size(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  rows = lines_of(ctx).map { |line| line.split("\t") }
  exact = decode_requests(rows.map { |row| row[0] }, rows.map { |row| row[2] })
  less = decode_requests(rows.map { |row| row[0] }, rows.map { |row| "#{row[2].to_i! - 1}" })
  for i in 0...rows.size
    if exact[i] != "ok\t#{rows[i][1]}"
      return BDD.assert(ctx, false, "#{shown(rows[i][0])} at its size: #{shown(exact[i])}")
    end

    if less[i].split("\t").take(2) != ["error", "zstd.too_large"]
      return BDD.assert(ctx, false, "#{shown(rows[i][0])} one byte short: #{shown(less[i])}")
    end
  end

  BDD.assert(ctx, rows.size > 0, "no frames to check")
end

def damaged_frames(ctx: BDD.Context, args: List[String]) -> BDD.Context
  keep_lines(ctx, "damaged", args[1].to_i!, args[0].to_i!)
end

def decode_requests(frames: List[String], limits: List[String]) -> List[String]
  answers = drive((0...frames.size).map { |i| "decode\t#{limits[i]}\t#{frames[i]}" })
  answers
end

def reads_as_peer_says(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  rows = lines_of(ctx).map { |line| line.split("\t") }
  answers = decode_requests(rows.map { |row| row[0] }, rows.map { |_| "#{LIMIT}" })
  return BDD.assert(ctx, false, "the driver answered #{answers.size} of #{rows.size}") if answers.size != rows.size

  for i in 0...rows.size
    if answers[i] != "ok\t#{rows[i][1]}"
      return BDD.assert(ctx, false, "#{rows[i][0]} gave #{shown(answers[i])}, not the peer's data")
    end
  end

  BDD.assert(ctx, rows.size > 0, "no frames to check")
end

# The fast 4-stream decoder of libzstd does not look for the bits left over at the end of a Huffman stream, or read
# past its start, so `zstd` accepts some damaged frames and gives data that depends on how it reads past the stream.
# The codec refuses them, with an error that names the Huffman stream (`stricter`); it never accepts what the
# reference refuses, and from what both accept it reads the same data.
def agrees_on_damaged(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  rows = lines_of(ctx).map { |line| line.split("\t") }
  answers = decode_requests(rows.map { |row| row[0] }, rows.map { |_| "#{LIMIT}" })
  return BDD.assert(ctx, false, "the driver answered #{answers.size} of #{rows.size}") if answers.size != rows.size

  same = 0
  refused = 0
  stricter = 0
  for i in 0...rows.size
    seen = answers[i].split("\t")
    if seen[0] == "ok"
      if seen[1] != rows[i][1]
        return BDD.assert(ctx, false, "#{rows[i][0]}: the codec reads data, the peer says #{rows[i][1]}")
      end

      same += 1
    elsif not KINDS.include?(seen[1])
      return BDD.assert(ctx, false, "#{rows[i][0]}: the codec says #{shown(answers[i])}")
    elsif rows[i][1] == "error"
      refused += 1
    elsif seen[2].include?("Huffman stream")
      stricter += 1
    else
      return BDD.assert(ctx, false, "#{rows[i][0]}: the codec refuses what the peer reads: #{shown(answers[i])}")
    end
  end

  BDD.assert(ctx, same > 0 and refused > 0, "#{same} read, #{refused} refused, #{stricter} stricter")
end

def checked_frames(ctx: BDD.Context, args: List[String]) -> BDD.Context
  keep_lines(ctx, "checked", args[1].to_i!, args[0].to_i!)
end

# Every cut of the frame is an error of the malformed kind.
def cut_everywhere(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  answers = drive(lines_of(ctx).map { |line| "cuts\t#{line.split("\t")[0]}" })
  BDD.assert(ctx, answers == ["ok=0 kinds=#{MALFORMED}"], "the cuts gave #{answers}")
end

# A frame with a checksum gives back its data or an error for each flipped bit; it never gives other data.
def flipped_everywhere(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  row = lines_of(ctx)[0].split("\t")
  answers = drive(["flips\t#{row[0]}\t#{row[1]}"])
  return BDD.assert(ctx, false, "the driver answered #{answers}") if answers.size != 1

  fields = answers[0].split(" ")
  bits = (row[0].length / 2) * 8
  refused = fields[2].replace("refused=", "").to_i!
  same = fields[0].replace("same=", "").to_i!
  ok_other = fields[1] == "other=0"
  BDD.assert(
    ctx,
    ok_other and refused > bits / 2 and same + refused == bits,
    "the flips gave #{answers[0]} of #{bits}",
  )
end

def shown(text: String) -> String
  return text if text.length <= 60

  text.slice(0, 60) + "..."
end
