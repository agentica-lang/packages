## The steps of the features. The steps of `codec.feature` run the codec against `fixtures/dns_peer.py`; the ones of
## `transport.feature` are below them (see the header of `fixtures/dns_tcp_peer.agc`).
##
## The codec peer is `fixtures/dns_peer.py`: a step starts it, reads what it prints (a message in hex and the text that
## the peer made of it, a tab between), and the codec reads the same bytes. Both sides write a message as the same line
## of text, so the check is one string compare.

import BDD from "std/bdd"
import DNS from "../dns"
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
    BDD.step("the peer listens with the script {string}", &peer_listens),
    BDD.step("the TLS peer listens with the script {string}", &tls_peer_listens),
    BDD.step("the nameservers are:", &nameservers_are),
    BDD.step("each nameserver has {int} milliseconds", &each_has),
    BDD.step("the client trusts the CA of the specs", &trusts_ca),
    BDD.step("the resolver asks for the {string} addresses of {string}", &asks_addresses),
    BDD.step("the resolver looks up {string}", &looks_up),
    BDD.step("the resolver allows {int} CNAMEs", &allows_cnames),
    BDD.step("it gives {string}", &it_gives),
    BDD.step("it fails with {string}", &it_fails_with),
    BDD.step("it took less than {int} milliseconds", &took_less),
    BDD.step("the peer saw {string}", &peer_saw),
  ])
end

private

PEER = "specs/fixtures/dns_peer.py"
LINES = "lines"
QUERY = "query"
FAILURE = "failure"
PYTHON_MS = 60_000
PEER_PROGRAM = "fixtures/dns_tcp_peer.agc"
PEER_CERTIFICATE = "fixtures/server.pem"
PEER_KEY = "fixtures/server.key"
CA = "specs/fixtures/ca.pem"
PORT = "port"
CLOSED = "closed"
SERVERS = "servers"
TIMEOUT = "timeout"
CNAMES = "cnames"
TRUSTS = "trusts"
OUTCOME = "outcome"
START_MS = 10_000
PEER_MS = 5_000
KINDS = [
  DNS.MALFORMED,
  DNS.NXDOMAIN,
  DNS.SERVFAIL,
  DNS.REFUSED,
  DNS.TRUNCATED,
  DNS.TIMEOUT,
  DNS.NETWORK,
  DNS.MISMATCH,
  DNS.CNAME_LIMIT,
  DNS.NO_ADDRESS,
]

# What the client got: the text of the answer or of the error, the kind of an error, and the time it took.
struct Outcome
  text: String = ""
  kind: String = ""
  elapsed: Int = 0
end

def run_peer(args: List[String], input: String) -> String
  process = Process.spawn_captured("python3", [PEER] + args, Process.Options(timeout_ms: PYTHON_MS)).unwrap!
  if input != ""
    _ = Process.send(process, input, PYTHON_MS)
    _ = Process.close_stdin(process, PYTHON_MS)
  end

  output = Process.output(process, PYTHON_MS).unwrap!
  _ = Process.wait(process, PYTHON_MS)
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

def start_peer(ctx: BDD.Context, script: String, secure: Bool) -> BDD.Context
  armed = ctx
  if secure
    armed = BDD.given_env(BDD.given_env(armed, "TLS_CERT", PEER_CERTIFICATE), "TLS_KEY", PEER_KEY)
  end

  for line in script.split(" / ")
    armed = BDD.given_argument(armed, line.strip)
  end

  started = BDD.given_program(armed, PEER_PROGRAM)
  port = BDD.read_line(started, START_MS).unwrap!.split(" ").last.to_i!
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  closed = TCP.local_port(listener)
  TCP.close_listener(listener)
  BDD.set(BDD.set(started, PORT, JSON.from(port)), CLOSED, JSON.from(closed))
end

def peer_listens(ctx: BDD.Context, args: List[String]) -> BDD.Context = start_peer(ctx, args[0], false)

def tls_peer_listens(ctx: BDD.Context, args: List[String]) -> BDD.Context = start_peer(ctx, args[0], true)

def number(ctx: BDD.Context, name: String, fallback: Int) -> Int
  case BDD.get(ctx, name)
    ok(value) -> JSON.int(value).unwrap_or(fallback)
    error(_) -> fallback
  end
end

def nameservers_are(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  rows = BDD.table(ctx).drop(1)
  BDD.set(ctx, SERVERS, JSON.from(rows))
end

def each_has(ctx: BDD.Context, args: List[String]) -> BDD.Context = BDD.set(ctx, TIMEOUT, JSON.from(args[0].to_i!))

def allows_cnames(ctx: BDD.Context, args: List[String]) -> BDD.Context = BDD.set(ctx, CNAMES, JSON.from(args[0].to_i!))

def trusts_ca(ctx: BDD.Context, _args: List[String]) -> BDD.Context = BDD.set(ctx, TRUSTS, JSON.from(true))

def server_of(ctx: BDD.Context, row: List[String]) -> DNS.Server
  port = number(ctx, PORT, 0)
  if row[1] == "CLOSED"
    port = number(ctx, CLOSED, 0)
  end

  return DNS.Server.Tls("127.0.0.1", port, row[2]) if row[0] == "tls"

  DNS.Server.Tcp("127.0.0.1", port)
end

def resolver_of(ctx: BDD.Context) -> DNS.Resolver
  rows = JSON.list(BDD.get(ctx, SERVERS).unwrap!).unwrap!
  servers = rows.map { |row| server_of(ctx, JSON.list(row).unwrap!.map { |cell| JSON.string(cell).unwrap! }) }
  context: Optional[TLS.Context] = none
  if number(ctx, TRUSTS, 0) != 0 or BDD.get(ctx, TRUSTS).ok?
    context = some(TLS.client_context(TLS.ClientOptions(ca_file: CA)).unwrap!)
  end

  options = DNS.Options(timeout_ms: number(ctx, TIMEOUT, 3000), max_cnames: number(ctx, CNAMES, 8), tls: context)
  DNS.resolver(servers, options).unwrap!
end

def kind_of(e: Error) -> String
  for kind in KINDS
    return kind if e.is_a?(kind)
  end

  "other"
end

def keep_outcome(ctx: BDD.Context, text: String, kind: String, started: Int) -> BDD.Context
  outcome = Outcome(text: text, kind: kind, elapsed: Time.monotonic_ms() - started)
  BDD.set(ctx, OUTCOME, JSON.from(outcome))
end

def kept(ctx: BDD.Context) -> Outcome
  value = BDD.get(ctx, OUTCOME).unwrap!
  Outcome(
    text: JSON.string(JSON.get(value, "text").unwrap!).unwrap!,
    kind: JSON.string(JSON.get(value, "kind").unwrap!).unwrap!,
    elapsed: JSON.int(JSON.get(value, "elapsed").unwrap!).unwrap!,
  )
end

def asks_addresses(ctx: BDD.Context, args: List[String]) -> BDD.Context
  type = DNS.TYPE_A
  if args[0] == "AAAA"
    type = DNS.TYPE_AAAA
  end

  started = Time.monotonic_ms()
  case DNS.addresses(resolver_of(ctx), args[1], type)
    ok(found) -> keep_outcome(ctx, found.map { |a| "#{a.address}/#{a.ttl}" }.join(","), "", started)
    error(e) -> keep_outcome(ctx, e.message, kind_of(e), started)
  end
end

def looks_up(ctx: BDD.Context, args: List[String]) -> BDD.Context
  started = Time.monotonic_ms()
  case DNS.lookup(resolver_of(ctx), args[0])
    ok(found) -> keep_outcome(ctx, found.join(","), "", started)
    error(e) -> keep_outcome(ctx, e.message, kind_of(e), started)
  end
end

def it_gives(ctx: BDD.Context, args: List[String]) -> BDD.Context
  outcome = kept(ctx)
  BDD.assert(ctx, outcome.kind == "" and outcome.text == args[0], "it gave \"#{outcome.text}\" (#{outcome.kind})")
end

def it_fails_with(ctx: BDD.Context, args: List[String]) -> BDD.Context
  outcome = kept(ctx)
  BDD.assert(ctx, outcome.kind == args[0], "it ended with \"#{outcome.kind}\": #{outcome.text}")
end

def took_less(ctx: BDD.Context, args: List[String]) -> BDD.Context
  elapsed = kept(ctx).elapsed
  BDD.assert(ctx, elapsed < args[0].to_i!, "it took #{elapsed} milliseconds")
end

def peer_saw(ctx: BDD.Context, args: List[String]) -> BDD.Context = BDD.then_line(ctx, args[0], PEER_MS)
