## The steps of `codec.feature`. The peer is `fixtures/dns_peer.py`: a step starts it, reads what it prints (a message in
## hex and the text that the peer made of it, a tab between), and the codec reads the same bytes. Both sides write a
## message as the same line of text, so the check is one string compare.

import BDD from "std/bdd"
import Types from "../src/types"
import Wire from "../src/wire"

def main() -> Void
  BDD.run([
    BDD.step("the peer writes {int} random messages from the seed {int}", &random_messages),
    BDD.step("the peer writes {int} damaged messages from the seed {int}", &damaged_messages),
    BDD.step("the codec reads every one as the peer says", &reads_as_peer_says),
    BDD.step("the codec reads every one as the peer does", &reads_as_peer_does),
    BDD.step("the codec writes a query with the id {int} for {string} of the type {int}", &writes_query),
    BDD.step("the peer reads it as {string}", &peer_reads_it),
    BDD.step("writing fails with {string}", &writing_fails),
  ])
end

private

PEER = "specs/fixtures/dns_peer.py"
LINES = "lines"
QUERY = "query"
FAILURE = "failure"
PEER_MS = 60_000

def run_peer(args: List[String], input: String) -> String
  process = Process.spawn_captured("python3", [PEER] + args, Process.Options(timeout_ms: PEER_MS)).unwrap!
  if input != ""
    _ = Process.send(process, input, PEER_MS)
    _ = Process.close_stdin(process, PEER_MS)
  end

  output = Process.output(process, PEER_MS).unwrap!
  _ = Process.wait(process, PEER_MS)
  output.stdout
end

def keep_lines(ctx: BDD.Context, mode: String, count: Int, seed: Int) -> BDD.Context
  text = run_peer([mode, "#{seed}", "#{count}"], "")
  lines = text.split("\n").select { |line| line != "" }
  BDD.assert(BDD.set(ctx, LINES, JSON.from(lines)), lines.length == count, "the peer wrote #{lines.length} lines")
end

def random_messages(ctx: BDD.Context, args: List[String]) -> BDD.Context
  keep_lines(ctx, "generate", args[0].to_i!, args[1].to_i!)
end

def damaged_messages(ctx: BDD.Context, args: List[String]) -> BDD.Context
  keep_lines(ctx, "mutate", args[0].to_i!, args[1].to_i!)
end

def lines_of(ctx: BDD.Context) -> List[String]
  rows = JSON.list(BDD.get(ctx, LINES).unwrap!).unwrap!
  rows.map { |row| JSON.string(row).unwrap! }
end

def reads_as_peer_says(ctx: BDD.Context, _args: List[String]) -> BDD.Context = agree(ctx)

def reads_as_peer_does(ctx: BDD.Context, _args: List[String]) -> BDD.Context = agree(ctx)

# The codec reads each message of the peer; the first one where it differs is the failure, with its bytes.
def agree(ctx: BDD.Context) -> BDD.Context
  accepted = 0
  for line in lines_of(ctx)
    parts = line.split("\t")
    seen = canonical(Wire.decode(OpenSSL.Digest.hexdecode(parts[0]).unwrap!))
    return BDD.assert(ctx, false, "#{parts[0]}: the codec says #{seen}, the peer #{parts[1]}") if seen != parts[1]

    if seen != "error"
      accepted += 1
    end
  end

  BDD.assert(ctx, accepted > 0, "the codec accepted no message")
end

def canonical(message: Result[Types.Message]) -> String
  case message
    ok(m) -> text_of(m)
    error(_) -> "error"
  end
end

def text_of(m: Types.Message) -> String
  head = [
    "id=#{m.id}",
    "qr=#{bit(m.response)}",
    "op=#{m.opcode}",
    "aa=#{bit(m.authoritative)}",
    "tc=#{bit(m.truncated)}",
    "rd=#{bit(m.recursion_desired)}",
    "ra=#{bit(m.recursion_available)}",
    "rcode=#{m.rcode}",
  ]

  parts = [head.join(" ")]
  for q in m.questions
    parts = parts.push("Q #{q.name} #{q.type} #{q.class}")
  end

  parts = parts + m.answers.map { |r| record_text("AN", r) }
  parts = parts + m.authorities.map { |r| record_text("NS", r) }
  parts = parts + m.additionals.map { |r| record_text("AR", r) }
  parts.join(" ; ")
end

def bit(flag: Bool) -> Int
  return 1 if flag

  0
end

def record_text(tag: String, r: Types.Record) -> String
  "#{tag} #{r.name} #{r.type} #{r.class} #{r.ttl} #{data_text(r.data)}"
end

def data_text(data: Types.Data) -> String
  case data
    Types.Data.A(address) -> "A:#{address}"
    Types.Data.Aaaa(address) -> "AAAA:#{address}"
    Types.Data.Cname(name) -> "CNAME:#{name}"
    Types.Data.Ns(name) -> "NS:#{name}"
    Types.Data.Ptr(name) -> "PTR:#{name}"
    Types.Data.Other(bytes) -> "RAW:#{OpenSSL.Digest.hexencode(bytes)}"
  end
end

def writes_query(ctx: BDD.Context, args: List[String]) -> BDD.Context
  written = Wire.encode_query(args[0].to_i!, args[1], args[2].to_i!)
  case written
    ok(bytes) -> BDD.set(ctx, QUERY, JSON.from(OpenSSL.Digest.hexencode(bytes)))
    error(e) -> BDD.set(ctx, FAILURE, JSON.from(failure_kind(e)))
  end
end

def failure_kind(e: Error) -> String
  return Types.MALFORMED if e.is_a?(Types.MALFORMED)

  e.message
end

def peer_reads_it(ctx: BDD.Context, args: List[String]) -> BDD.Context
  hex = JSON.string(BDD.get(ctx, QUERY).unwrap!).unwrap!
  read = run_peer(["decode"], hex + "\n").strip
  BDD.assert(ctx, read == args[0], "the peer reads #{read}")
end

def writing_fails(ctx: BDD.Context, args: List[String]) -> BDD.Context
  kind = JSON.string(BDD.get(ctx, FAILURE).unwrap_or(JSON.from(""))).unwrap_or("")
  BDD.assert(ctx, kind == args[0], "the failure is #{kind}")
end
