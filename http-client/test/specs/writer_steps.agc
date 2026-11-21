import Dial from "../../src/dial"
import Connection from "../../src/http2/connection"
import Origin from "../../src/http2/origin"
import Session from "../../src/http2/session"
import Url from "../../src/url"
import Peer from "fixtures/h2_peer"
import BDD from "std/bdd"
import HTTP from "std/http"

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

def pool_timeout(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  case exercise_end(false, false, 100)
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

def exercise_end(peer_resets: Bool, eof: Bool, wait_ms: Int = 2_000) -> Result[Void]
  listener = try TCP.listen("127.0.0.1", 0)
  gate = Gate(blocked: Channel.new(1), release: Channel.new(1), cleared: Channel.new(1))
  peer = Task.spawn do peer_exchange(listener, gate, peer_resets, eof) end

  result = exchange(TCP.local_port(listener), gate, eof, wait_ms)
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

def exchange(port: Int, gate: Gate, eof: Bool, wait_ms: Int) -> Result[Void]
  base = "http://127.0.0.1:#{port}"
  cache: ATS[String, Dial.Resolved] = ATS.new()
  dialer = Dial.Dialer(
    own: false,
    resolver: ->(_host) { ok(["127.0.0.1"]) },
    cache: cache,
    cache_ms: 0,
    public_only: false,
  )

  idle_ms = 5_000
  if wait_ms == 100
    idle_ms = 75
  end

  config = Origin.Config(
    origin: base,
    dialer: dialer,
    options: HTTP.ClientOptions(),
    size: 1,
    wait_ms: wait_ms,
    idle_ms: idle_ms,
    send: some(->(socket, bytes, queued) { gated_send(socket, bytes, queued, gate) }),
  )

  origin = Origin.start(config)
  result = requests(origin, base, gate, eof, wait_ms)
  _ = Origin.close(origin, 0)
  result
end

def requests(origin: Origin.Origin, base: String, gate: Gate, eof: Bool, wait_ms: Int) -> Result[Void]
  deadline = Time.monotonic_ms() + 700
  post = try send_request(origin, base, "POST", "/early", ("x" * 20_000).bytes, deadline)
  return error("expected an early 413") if post.status != 413
  return error("the early response body was lost") if post.body != "complete".bytes
  return ok() if eof

  if wait_ms == 100
    try check_pool_timeout(origin, base)
    try release_writer(gate, deadline)
    following = try send_request(origin, base, "GET", "/after", "".bytes, Time.monotonic_ms() + 2_000)
    return error("expected response status 200") if following.status != 200
    return ok()
  end

  successor = Task.spawn do send_request(origin, base, "GET", "/after", "".bytes, Time.monotonic_ms() + 2_000) end
  try release_writer(gate, deadline)
  result = try Task.await(successor)
  return error("expected response status 200") if result.status != 200
  ok()
end

def check_pool_timeout(origin: Origin.Origin, base: String) -> Result[Void]
  result = send_request(origin, base, "GET", "/never", "".bytes, Time.monotonic_ms() + 2_000)
  case result
    error(e) if e.is_a?("http_client.timeout.pool") -> ok()
    error(e) -> error("expected pool timeout, got #{e.kind}")
    ok(_) -> error("the retiring stream admitted a request")
  end
end

def release_writer(gate: Gate, deadline: Int) -> Result[Void]
  Task.sleep([deadline - Time.monotonic_ms() + 10, 1].max.unwrap!)
  try gate.release.send(true, 100)
  _ = try gate.cleared.recv(2_000)
  ok()
end

def send_request(
  origin: Origin.Origin,
  base: String,
  method: String,
  path: String,
  body: Bytes,
  deadline: Int,
) -> Result[Connection.Response]
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

  Origin.request(origin, req, 1_000)
end

def gated_send(socket: TCP.Socket, bytes: Bytes, queued: Fn[Bool], gate: Gate) -> Result[Void]
  if bytes[3] == 0 and bytes[4] == 0
    deadline = Time.monotonic_ms() + 1_000
    while not queued.call()
      return error("the final DATA did not enter the writer queue") if Time.monotonic_ms() >= deadline
      Task.sleep(1)
    end

    try gate.blocked.send(true, 100)
    _ = try gate.release.recv(2_000)
  end

  TCP.send_bytes(socket, bytes, 2_000)
end
