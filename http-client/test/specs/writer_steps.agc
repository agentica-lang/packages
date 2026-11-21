import Url from "../../src/url"
import Peer from "fixtures/h2_peer"
import Messages from "../../src/http2/messages"
import HTTP from "std/http"
import Headers from "../../src/http2/headers"
import Dial from "../../src/dial"
import Actor from "std/actor"
import BDD from "std/bdd"
import Connection from "../../src/http2/connection"
import Session from "../../src/http2/session"

def expired(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  case exercise()
    ok(_) -> BDD.assert(ctx, true, "")
    error(e) -> BDD.assert(ctx, false, e.message)
  end
end

def skipped_end(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  case exercise_end(false, false)
    ok(_) -> BDD.assert(ctx, true, "")
    error(e) -> BDD.assert(ctx, false, e.message)
  end
end

def reset_by_peer(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  case exercise_end(true, false)
    ok(_) -> BDD.assert(ctx, true, "")
    error(e) -> BDD.assert(ctx, false, e.message)
  end
end

def eof(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  case exercise_end(false, true)
    ok(_) -> BDD.assert(ctx, true, "")
    error(e) -> BDD.assert(ctx, false, e.message)
  end
end

private

struct Gate
  blocked: Channel[Bool]
  release: Channel[Bool]
  cleared: Channel[Bool]
end

def exercise() -> Result[Void]
  out: Channel[Connection.Write] = Channel.new(8)
  inbox: Channel[Session.Msg] = Channel.new(8)
  writes: Channel[Bytes] = Channel.new(8)
  gate: Channel[Bool] = Channel.new(1)
  writer = Task.spawn do Session.write_loop(out, inbox, ->(bytes) { write(bytes, writes, gate) }) end
  result = queued(out, inbox, writes, gate)
  out.close
  Task.cancel(writer)
  _ = Task.await(writer)
  result
end

def queued(
  out: Channel[Connection.Write],
  inbox: Channel[Session.Msg],
  writes: Channel[Bytes],
  gate: Channel[Bool],
) -> Result[Void]
  try out.send(Connection.Write(bytes: "first".bytes), 100)
  first = try writes.recv(1_000)
  return error("expected the first write") if first != "first".bytes
  until = Time.monotonic_ms() + 20
  try out.send(Connection.Write(bytes: "expired headers".bytes, stream: 1, deadline: some(until), opening: true), 100)
  try out.send(Connection.Write(bytes: "expired data".bytes, stream: 1, deadline: some(until), credit: 7), 100)
  try out.send(Connection.Write(bytes: "invalid reset".bytes, stream: 1, reset: true), 100)
  try out.send(Connection.Write(bytes: "other stream".bytes, stream: 3), 100)
  Task.sleep(30)
  try gate.send(true, 100)
  other = try writes.recv(1_000)
  return error("a skipped write reached the socket") if other != "other stream".bytes
  try skipped(inbox, 0)
  skipped(inbox, 7)
end

def write(bytes: Bytes, writes: Channel[Bytes], gate: Channel[Bool]) -> Result[Void]
  try writes.send(bytes, 100)
  if bytes == "first".bytes
    _ = try gate.recv(1_000)
  end

  ok()
end

def skipped(inbox: Channel[Session.Msg], credit: Int) -> Result[Void]
  for _ in 0..3
    case try inbox.recv(1_000)
      Session.Msg.Skipped(item) if item.credit == credit -> return ok()
      Session.Msg.Skipped(_) -> return error("incorrect refunded credit")
      _ -> nil
    end
  end

  error("the expired write was not reported")
end

def exercise_end(peer_resets: Bool, eof: Bool) -> Result[Void]
  listener = try TCP.listen("127.0.0.1", 0)
  gate = Gate(blocked: Channel.new(1), release: Channel.new(1), cleared: Channel.new(1))
  peer = Task.spawn do peer_exchange(listener, gate, peer_resets, eof) end

  result = exchange(TCP.local_port(listener), gate, eof)
  TCP.close_listener(listener)
  case Task.await(peer, 1_000)
    Await.Done(outcome) ->
      try result
      outcome
    Await.TimedOut ->
      Task.cancel(peer)
      _ = Task.await(peer)
      try result
      error("the peer did not finish")
  end
end

def peer_exchange(listener: TCP.Listener, gate: Gate, peer_resets: Bool, eof: Bool) -> Result[Void]
  return Peer.eof_during_upload(listener, gate.blocked) if eof
  Peer.skipped_end(listener, gate.blocked, gate.cleared, peer_resets)
end

def exchange(port: Int, gate: Gate, eof: Bool) -> Result[Void]
  owner: Channel[Messages.Origin] = Channel.new(16)
  base = "http://127.0.0.1:#{port}"
  cache: ATS[String, Dial.Resolved] = ATS.new()
  dialer = Dial.Dialer(
    own: false,
    resolver: ->(_host) { ok(["127.0.0.1"]) },
    cache: cache,
    cache_ms: 0,
    public_only: false,
  )

  config = Session.Config(
    id: 1,
    owner: owner.address,
    dialer: dialer,
    options: HTTP.ClientOptions(),
    origin: base,
    connect_deadline: Time.monotonic_ms() + 2_000,
    timeout_kind: "http_client.timeout.connect",
    send: some(->(socket, bytes) { gated_send(socket, bytes, gate) }),
  )

  session = Session.start(config)
  result = requests(session, owner, base, gate, eof)
  _ = Actor.cast(session.address, Session.Msg.Stop, 100)
  _ = Actor.stop(session, 1_000)
  result
end

def requests(
  session: Actor.Ref[Session.State, Session.Msg],
  owner: Channel[Messages.Origin],
  base: String,
  gate: Gate,
  eof: Bool,
) -> Result[Void]
  try Actor.cast(session.address, Session.Msg.Boot, 100)
  case try owner.recv(2_000)
    Messages.Origin.Capacity(_, 1, false) -> nil
    _ -> return error("expected a one-stream session")
  end

  deadline = Time.monotonic_ms() + 500
  try send_request(session.address, base, "POST", "/early", ("x" * 20_000).bytes, deadline)
  if eof
    read = try response(owner)
    return error("the buffered response did not drain at EOF") if read.status != 413 or read.body != "complete".bytes
    return ok()
  end

  try completed(owner, 413)
  try send_request(session.address, base, "GET", "/after", "".bytes, Time.monotonic_ms() + 2_000)
  Task.sleep([deadline - Time.monotonic_ms() + 10, 1].max.unwrap!)
  try gate.release.send(true, 100)
  _ = try gate.cleared.recv(2_000)
  completed(owner, 200)
end

def send_request(
  address: Address[Session.Msg],
  base: String,
  method: String,
  path: String,
  body: Bytes,
  deadline: Int,
) -> Result[Void]
  target = try Url.resolve(base, path)
  req = Connection.Request(
    method: method,
    target: target,
    headers: [],
    body: body,
    read_timeout_ms: 1_000,
    body_idle_ms: 1_000,
    deadline: deadline,
    max_body_bytes: 1_024,
  )

  reply: Channel[Result[Connection.Response]] = Channel.new(1)
  call = Messages.Call(
    request: req,
    connect_ms: 1_000,
    caller: Task.current,
    reply: reply,
    admission_deadline: deadline,
  )

  block = try Headers.encode(method, target, [], body.size)
  Actor.cast(address, Session.Msg.Open(call, block), 100)
end

def completed(owner: Channel[Messages.Origin], status: Int) -> Result[Void]
  received = try response(owner)
  return error("expected response status #{status}") if received.status != status
  ok()
end

def response(owner: Channel[Messages.Origin]) -> Result[Connection.Response]
  for _ in 1..4
    case try owner.recv(2_000)
      Messages.Origin.Complete(_, _, result) -> return result
      _ -> nil
    end
  end

  error("expected a response completion")
end

def gated_send(socket: TCP.Socket, bytes: Bytes, gate: Gate) -> Result[Void]
  if bytes[3] == 0 and bytes[4] == 0
    try gate.blocked.send(true, 100)
    _ = try gate.release.recv(2_000)
  end

  TCP.send_bytes(socket, bytes, 2_000)
end
