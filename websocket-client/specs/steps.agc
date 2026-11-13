## The steps of `websocket.feature`. The client is the one of the package, in the process of the scenario: a service of
## `BDD.keep` holds its connection and runs one order (send, receive, close) for each step. The peers are programs of
## `fixtures/` that a step starts (see the feature), so a step may halt on what is not the scenario's business.

import BDD from "std/bdd"
import Binary from "std/binary"
import HTTP from "std/http"
import WebSocket from "../websocket"

def steps() -> List[BDD.Step]
  [
    BDD.step("the std server listens on a free port", &std_server_listens),
    BDD.step("the std server listens with TLS on a free port", &tls_server_listens),
    BDD.step("the raw peer listens with the script:", &raw_peer_listens),
    BDD.step("the client sends the header {string} with {string}", &sends_header),
    BDD.step("the client offers the subprotocols {string}", &offers),
    BDD.step("the client trusts the certificate of the specs", &trusts),
    BDD.step("the client reads at most {int} bytes of a message", &reads_at_most),
    BDD.step("the client waits {int} milliseconds for a read", &waits_for_read),
    BDD.step("the client waits {int} milliseconds for the answer to a close", &waits_for_close),
    BDD.step("the client allows {int} milliseconds to connect", &allows_to_connect),
    BDD.step("the client waits for a read with no end", &waits_for_read_forever),
    BDD.step("the client waits for the answer to a close with no end", &waits_for_close_forever),
    BDD.step("the client allows no end to connect", &allows_connect_forever),
    BDD.step("the client connects to {string}", &connects),
    BDD.step("the client connects to a port that nobody listens at", &connects_to_nothing),
    BDD.step("the client performs the handshake with {string}", &performs_handshake),
    BDD.step("the handshake is open with the status {int}", &handshake_is_open),
    BDD.step("the handshake is refused with the status {int}", &handshake_is_refused),
    BDD.step("the answer has the header {string} with {string}", &answer_has_header),
    BDD.step("the answer has the body {string}", &answer_has_body),
    BDD.step("the answer body has {int} bytes", &answer_body_size_is),
    BDD.step("the connection took less than {int} milliseconds", &connection_took_less),
    BDD.step("the connection fails with {string}", &connection_fails),
    BDD.step("the subprotocol is {string}", &subprotocol_is),
    BDD.step("the client sends the text {string}", &sends_text),
    BDD.step("the client sends a text of {int} bytes", &sends_text_of),
    BDD.step("the client sends the binary {string}", &sends_binary),
    BDD.step("the client pings with {string}", &pings),
    BDD.step("the client pongs with {string}", &pongs),
    BDD.step("the client closes with {int} and {string}", &closes),
    BDD.step("the client receives the text {string}", &receives_text),
    BDD.step("the client receives a text of {int} bytes", &receives_text_of),
    BDD.step("the client receives the binary {string}", &receives_binary),
    BDD.step("the client receives the close {int} {string}", &receives_close),
    BDD.step("the client fails to receive with {string}", &fails_to_receive),
    BDD.step("the client has no connection", &has_no_connection),
    BDD.step("sending a ping of {int} bytes fails with {string}", &ping_fails),
    BDD.step("sending a text of {int} bytes fails with {string}", &text_fails),
    BDD.step("closing with {int} fails with {string}", &close_fails),
    BDD.step("a client with a read timeout with no end fails to receive with {string}", &huge_receive_fails),
    BDD.step("a client with a close timeout with no end fails to close with {string}", &huge_close_fails),
    BDD.step("the close took less than {int} milliseconds", &close_took_less),
    BDD.step("the peer saw {string}", &peer_saw),
    BDD.step("the peer saw a close frame with the code {int}", &peer_saw_close),
  ]
end

private

PORT = "port"
HEADERS = "headers"
PROTOCOLS = "protocols"
TRUSTS = "trusts"
MAX_BYTES = "max_bytes"
READ_MS = "read_ms"
CLOSE_MS = "close_ms"
TIMEOUT_MS = "timeout_ms"
ELAPSED = "elapsed"
HUGE = 9_223_372_036_854_775_807
FAILURE = "failure"
CLIENT = "client"
SERVER = "fixtures/server.agc"
RAW_PEER = "fixtures/raw_peer.agc"
# Relative to the working directory of the run, which is the package folder (`make test`); the programs of the peers
# run in the folder of the feature instead.
CERTIFICATE = "specs/fixtures/cert.pem"
PEER_CERTIFICATE = "fixtures/cert.pem"
PEER_KEY = "fixtures/key.pem"
START_MS = 10_000
PEER_MS = 5_000

struct Pair
  name: String
  value: String
end

struct Order
  op: String
  text: String = ""
  hex: String = ""
  size: Int = 0
  code: Int = 0
end

# The answer of the service: an error, or what a receive got.
struct Reply
  elapsed: Int = 0
  failed: Bool = false
  error: String = ""
  kind: String = ""
  text: String = ""
  hex: String = ""
  code: Int = 0
end

def port_line(ctx: BDD.Context) -> BDD.Context
  line = BDD.read_line(ctx, START_MS).unwrap!
  BDD.set(ctx, PORT, JSON.from(line.split(" ").last.to_i!))
end

def std_server_listens(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  port_line(BDD.given_program(ctx, SERVER))
end

def tls_server_listens(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  with_cert = BDD.given_env(ctx, "TLS_CERT", PEER_CERTIFICATE)
  port_line(BDD.given_program(BDD.given_env(with_cert, "TLS_KEY", PEER_KEY), SERVER))
end

def raw_peer_listens(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  armed = ctx
  for line in BDD.doc_string(ctx).split("\n")
    if not line.strip.empty?
      armed = BDD.given_argument(armed, line.strip)
    end
  end

  port_line(BDD.given_program(armed, RAW_PEER))
end

def int_setting(ctx: BDD.Context, name: String, fallback: Int) -> Int
  case BDD.get(ctx, name)
    ok(value) -> JSON.int(value).unwrap_or(fallback)
    error(_) -> fallback
  end
end

def pairs_of(ctx: BDD.Context) -> List[Pair]
  case BDD.get(ctx, HEADERS)
    ok(value) -> JSON.decode(value, List[Pair]).unwrap!
    error(_) -> []
  end
end

def sends_header(ctx: BDD.Context, args: List[String]) -> BDD.Context
  pairs = pairs_of(ctx).push(Pair(name: args[0], value: args[1]))
  BDD.set(ctx, HEADERS, JSON.from(pairs))
end

def offers(ctx: BDD.Context, args: List[String]) -> BDD.Context
  names = args[0].split(",").map do |name| name.strip end
  BDD.set(ctx, PROTOCOLS, JSON.from(names))
end

def trusts(ctx: BDD.Context, _args: List[String]) -> BDD.Context = BDD.set(ctx, TRUSTS, JSON.from(true))

def reads_at_most(ctx: BDD.Context, args: List[String]) -> BDD.Context
  BDD.set(ctx, MAX_BYTES, JSON.from(args[0].to_i!))
end

def waits_for_read(ctx: BDD.Context, args: List[String]) -> BDD.Context
  BDD.set(ctx, READ_MS, JSON.from(args[0].to_i!))
end

def waits_for_close(ctx: BDD.Context, args: List[String]) -> BDD.Context
  BDD.set(ctx, CLOSE_MS, JSON.from(args[0].to_i!))
end

def protocols_of(ctx: BDD.Context) -> List[String]
  case BDD.get(ctx, PROTOCOLS)
    ok(value) -> JSON.decode(value, List[String]).unwrap!
    error(_) -> []
  end
end

def allows_to_connect(ctx: BDD.Context, args: List[String]) -> BDD.Context
  BDD.set(ctx, TIMEOUT_MS, JSON.from(args[0].to_i!))
end

# The biggest Int: what a program writes for "never".
def waits_for_read_forever(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  BDD.set(ctx, READ_MS, JSON.from(HUGE))
end

def waits_for_close_forever(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  BDD.set(ctx, CLOSE_MS, JSON.from(HUGE))
end

def allows_connect_forever(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  BDD.set(ctx, TIMEOUT_MS, JSON.from(HUGE))
end

def options_of(ctx: BDD.Context) -> WebSocket.Options
  headers = pairs_of(ctx).map do |pair| HTTP.Header(name: pair.name, value: pair.value) end
  tls: Optional[TLS.Context] = none
  if BDD.get(ctx, TRUSTS).ok?
    tls = some(TLS.client_context(TLS.ClientOptions(ca_file: CERTIFICATE)).unwrap!)
  end

  WebSocket.Options(
    headers: headers,
    protocols: protocols_of(ctx),
    max_message_bytes: int_setting(ctx, MAX_BYTES, 1_048_576),
    timeout_ms: int_setting(ctx, TIMEOUT_MS, 30_000),
    read_timeout_ms: int_setting(ctx, READ_MS, 30_000),
    close_timeout_ms: int_setting(ctx, CLOSE_MS, 5_000),
    tls: tls,
  )
end

def serving(f: Fn[JSON.Value, Result[JSON.Value]]) -> Fn[JSON.Value, Result[JSON.Value]] = f

def connect_to(ctx: BDD.Context, url: String) -> BDD.Context
  started = Time.monotonic_ms()
  result = WebSocket.connect(url, options_of(ctx))
  timed = BDD.set(ctx, "connect elapsed", JSON.from(Time.monotonic_ms() - started))
  case result
    ok(ws) -> kept(timed, ws)
    error(e) -> BDD.set(timed, FAILURE, JSON.from(e.message))
  end
end

def kept(ctx: BDD.Context, ws: WebSocket.Client) -> BDD.Context
  service = serving do |request| drive(ws, request) end
  BDD.set(BDD.keep(ctx, CLIENT, service), "protocol", JSON.from(ws.protocol))
end

# What the answer of the handshake said, for the steps that follow: its kind, status, headers and body.
def noted(ctx: BDD.Context, kind: String, status: Int, headers: List[HTTP.Header], body: String) -> BDD.Context
  pairs = headers.map do |header| Pair(name: header.name, value: header.value) end
  with_kind = BDD.set(ctx, "answer kind", JSON.from(kind))
  with_status = BDD.set(with_kind, "answer status", JSON.from(status))
  BDD.set(BDD.set(with_status, "answer headers", JSON.from(pairs)), "answer body", JSON.from(body))
end

def performs_handshake(ctx: BDD.Context, args: List[String]) -> BDD.Context
  port = JSON.int(BDD.get(ctx, PORT).unwrap!).unwrap!
  case WebSocket.handshake(args[0].replace("PORT", "#{port}"), options_of(ctx))
    error(e) -> BDD.set(ctx, FAILURE, JSON.from(e.message))

    ok(answer) ->
      case answer
        WebSocket.Handshake.Open(ws) -> noted(kept(ctx, ws), "open", ws.status, ws.headers, "")
        WebSocket.Handshake.Refused(status, headers, body) -> noted(ctx, "refused", status, headers, body)
      end
  end
end

def answer_text(ctx: BDD.Context, name: String) -> String = JSON.string(BDD.get(ctx, name).unwrap!).unwrap!

def handshake_is_open(ctx: BDD.Context, args: List[String]) -> BDD.Context
  kind = answer_text(ctx, "answer kind")
  status = JSON.int(BDD.get(ctx, "answer status").unwrap!).unwrap!
  BDD.assert(ctx, kind == "open" and status == args[0].to_i!, "the handshake was #{kind} with #{status}")
end

def handshake_is_refused(ctx: BDD.Context, args: List[String]) -> BDD.Context
  kind = answer_text(ctx, "answer kind")
  status = JSON.int(BDD.get(ctx, "answer status").unwrap!).unwrap!
  BDD.assert(ctx, kind == "refused" and status == args[0].to_i!, "the handshake was #{kind} with #{status}")
end

def answer_has_header(ctx: BDD.Context, args: List[String]) -> BDD.Context
  pairs = JSON.decode(BDD.get(ctx, "answer headers").unwrap!, List[Pair]).unwrap!
  found = pairs.any? do |pair| pair.name == args[0] and pair.value == args[1] end
  BDD.assert(ctx, found, "no header #{args[0]}: #{args[1]} in #{pairs}")
end

def answer_has_body(ctx: BDD.Context, args: List[String]) -> BDD.Context
  body = answer_text(ctx, "answer body")
  BDD.assert(ctx, body == args[0], "the body is \"#{body}\"")
end

def answer_body_size_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  size = answer_text(ctx, "answer body").bytes.size
  BDD.assert(ctx, size == args[0].to_i!, "the body has #{size} bytes")
end

def connection_took_less(ctx: BDD.Context, args: List[String]) -> BDD.Context
  elapsed = JSON.int(BDD.get(ctx, "connect elapsed").unwrap!).unwrap!
  BDD.assert(ctx, elapsed < args[0].to_i!, "the connect took #{elapsed} ms")
end

def connects(ctx: BDD.Context, args: List[String]) -> BDD.Context
  port = JSON.int(BDD.get(ctx, PORT).unwrap!).unwrap!
  connect_to(ctx, args[0].replace("PORT", "#{port}"))
end

# A port that was just released: another program could take it before the connect, which is unlikely on localhost.
def connects_to_nothing(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  port = TCP.local_port(listener)
  TCP.close_listener(listener)
  connect_to(ctx, "ws://127.0.0.1:#{port}/")
end

def failure_of(ctx: BDD.Context) -> String
  case BDD.get(ctx, FAILURE)
    ok(value) -> JSON.string(value).unwrap_or("")
    error(_) -> ""
  end
end

def connection_fails(ctx: BDD.Context, args: List[String]) -> BDD.Context
  failure = failure_of(ctx)
  BDD.assert(ctx, failure.include?(args[0]), "the connection failed with \"#{failure}\", expected #{args[0]}")
end

def subprotocol_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  protocol = JSON.string(BDD.get(ctx, "protocol").unwrap!).unwrap!
  BDD.assert(ctx, protocol == args[0], "the subprotocol is \"#{protocol}\"")
end

def message_reply(message: WebSocket.Message) -> Reply
  case message
    WebSocket.Message.Text(text) -> Reply(kind: "text", text: text)
    WebSocket.Message.Binary(data) -> Reply(kind: "binary", hex: OpenSSL.Digest.hexencode(data))
    WebSocket.Message.Close(code, reason) -> Reply(kind: "close", code: code, text: reason)
  end
end

def done(result: Result[Void]) -> Reply
  case result
    ok(_) -> Reply()
    error(e) -> Reply(failed: true, error: e.message)
  end
end

def timed_close(ws: WebSocket.Client, order: Order) -> Reply
  started = Time.monotonic_ms()
  reply = done(WebSocket.close(ws, order.code, order.text))
  Reply(elapsed: Time.monotonic_ms() - started, failed: reply.failed, error: reply.error)
end

# The same connection with options that a program could write after the connect (the `Client` is a plain record).
def forever_receive(ws: WebSocket.Client) -> Reply
  other = WebSocket.Client(socket: ws.socket, protocol: ws.protocol, options: WebSocket.Options(read_timeout_ms: HUGE))
  case WebSocket.receive(other)
    ok(message) -> message_reply(message)
    error(e) -> Reply(failed: true, error: e.message)
  end
end

def forever_close(ws: WebSocket.Client) -> Reply
  other = WebSocket.Client(
    socket: ws.socket,
    protocol: ws.protocol,
    options: WebSocket.Options(close_timeout_ms: HUGE),
  )

  done(WebSocket.close(other, 1000, ""))
end

def run(ws: WebSocket.Client, order: Order) -> Reply
  case order.op
    "text" -> done(WebSocket.send_text(ws, order.text))
    "text_of" -> done(WebSocket.send_text(ws, "x" * order.size))
    "binary" -> done(WebSocket.send_binary(ws, OpenSSL.Digest.hexdecode(order.hex).unwrap!))
    "ping" -> done(WebSocket.send_ping(ws, order.text.bytes))
    "ping_of" -> done(WebSocket.send_ping(ws, ("x" * order.size).bytes))
    "pong" -> done(WebSocket.send_pong(ws, order.text.bytes))
    "close" -> timed_close(ws, order)
    "receive_forever" -> forever_receive(ws)
    "close_forever" -> forever_close(ws)
    _ ->
      case WebSocket.receive(ws)
        ok(message) -> message_reply(message)
        error(e) -> Reply(failed: true, error: e.message)
      end
  end
end

def drive(ws: WebSocket.Client, request: JSON.Value) -> Result[JSON.Value]
  order = try JSON.decode(request, Order)
  ok(JSON.from(run(ws, order)))
end

def ask(ctx: BDD.Context, order: Order) -> Reply
  case BDD.call(ctx, CLIENT, JSON.from(order))
    ok(json) -> JSON.decode(json, Reply).unwrap!
    error(_) -> Reply(failed: true, error: "the client is not connected: #{failure_of(ctx)}")
  end
end

# A step that sends is right when the send worked.
def sent(ctx: BDD.Context, order: Order) -> BDD.Context
  reply = ask(ctx, order)
  BDD.assert(ctx, not reply.failed, "the client could not #{order.op}: #{reply.error}")
end

def sends_text(ctx: BDD.Context, args: List[String]) -> BDD.Context = sent(ctx, Order(op: "text", text: args[0]))

def sends_text_of(ctx: BDD.Context, args: List[String]) -> BDD.Context
  sent(ctx, Order(op: "text_of", size: args[0].to_i!))
end

def sends_binary(ctx: BDD.Context, args: List[String]) -> BDD.Context = sent(ctx, Order(op: "binary", hex: args[0]))

def pings(ctx: BDD.Context, args: List[String]) -> BDD.Context = sent(ctx, Order(op: "ping", text: args[0]))

def pongs(ctx: BDD.Context, args: List[String]) -> BDD.Context = sent(ctx, Order(op: "pong", text: args[0]))

def closes(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = ask(ctx, Order(op: "close", code: args[0].to_i!, text: args[1]))
  BDD.assert(ctx, not reply.failed, "the client could not close: #{reply.error}")
  BDD.set(ctx, ELAPSED, JSON.from(reply.elapsed))
end

def close_took_less(ctx: BDD.Context, args: List[String]) -> BDD.Context
  elapsed = JSON.int(BDD.get(ctx, ELAPSED).unwrap!).unwrap!
  BDD.assert(ctx, elapsed < args[0].to_i!, "the close took #{elapsed} ms")
end

def huge_receive_fails(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = ask(ctx, Order(op: "receive_forever"))
  BDD.assert(ctx, reply.failed and reply.error.include?(args[0]), "the receive gave \"#{reply.error}\"")
end

def huge_close_fails(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = ask(ctx, Order(op: "close_forever"))
  BDD.assert(ctx, reply.failed and reply.error.include?(args[0]), "the close gave \"#{reply.error}\"")
end

def received(ctx: BDD.Context, kind: String) -> Reply
  reply = ask(ctx, Order(op: "receive"))
  BDD.assert(ctx, not reply.failed, "the client failed to receive: #{reply.error}")
  BDD.assert(ctx, reply.kind == kind, "the client received a #{reply.kind}, expected a #{kind}")
  reply
end

def receives_text(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = received(ctx, "text")
  BDD.assert(ctx, reply.text == args[0], "the client received \"#{reply.text}\", expected \"#{args[0]}\"")
end

def receives_text_of(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = received(ctx, "text")
  BDD.assert(ctx, reply.text == "x" * args[0].to_i!, "the client received a text of #{reply.text.bytes.size} bytes")
end

def receives_binary(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = received(ctx, "binary")
  BDD.assert(ctx, reply.hex == args[0], "the client received #{reply.hex}, expected #{args[0]}")
end

def receives_close(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = received(ctx, "close")
  BDD.assert(
    ctx,
    reply.code == args[0].to_i! and reply.text == args[1],
    "the close is #{reply.code} \"#{reply.text}\", expected #{args[0]} \"#{args[1]}\"",
  )
end

def fails_to_receive(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = ask(ctx, Order(op: "receive"))
  BDD.assert(ctx, reply.failed, "the client received a #{reply.kind}")
  BDD.assert(ctx, reply.error.include?(args[0]), "the error is \"#{reply.error}\", expected #{args[0]}")
end

# Whether the end was a close that the client sent or one that it answered, the socket is closed after it.
def has_no_connection(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  reply = ask(ctx, Order(op: "receive"))
  BDD.assert(ctx, reply.failed, "the client still gets messages")
end

def ping_fails(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = ask(ctx, Order(op: "ping_of", size: args[0].to_i!))
  BDD.assert(ctx, reply.failed and reply.error.include?(args[1]), "the ping gave \"#{reply.error}\"")
end

def text_fails(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = ask(ctx, Order(op: "text_of", size: args[0].to_i!))
  BDD.assert(ctx, reply.failed and reply.error.include?(args[1]), "the text gave \"#{reply.error}\"")
end

def close_fails(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = ask(ctx, Order(op: "close", code: args[0].to_i!))
  BDD.assert(ctx, reply.failed and reply.error.include?(args[1]), "the close gave \"#{reply.error}\"")
end

# PORT in the line is the port of the peer.
def peer_saw(ctx: BDD.Context, args: List[String]) -> BDD.Context
  port = JSON.int(BDD.get(ctx, PORT).unwrap!).unwrap!
  BDD.then_line(ctx, args[0].replace("PORT", "#{port}"), PEER_MS)
end

def peer_saw_close(ctx: BDD.Context, args: List[String]) -> BDD.Context
  line = BDD.read_line(ctx, PEER_MS).unwrap!
  code = OpenSSL.Digest.hexencode(Binary.write_u16_be(args[0].to_i!).unwrap!)
  prefix = "frame op=8 fin=true masked=true payload=#{code}"
  BDD.assert(ctx, line.start_with?(prefix), "the peer saw \"#{line}\", expected a close frame with #{prefix}")
end

def main() -> Void
  BDD.run(steps())
end
