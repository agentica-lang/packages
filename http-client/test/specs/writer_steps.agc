import Actor from "std/actor"
import Dial from "../../src/dial"
import Connection from "../../src/http2/connection"
import Frame from "../../src/http2/frame"
import Messages from "../../src/http2/messages"
import Origin from "../../src/http2/origin"
import Session from "../../src/http2/session"
import Url from "../../src/url"
import Peer from "fixtures/h2_peer"
import BDD from "std/bdd"
import HTTP from "std/http"
import Hpack from "pkg/hpack/hpack"

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

def malformed_timeout(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  case exercise_malformed()
    ok(_) -> BDD.assert(ctx, true, "")
    error(e) -> BDD.assert(ctx, false, e.message)
  end
end

def reuse(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  case exercise_reuse()
    ok(_) -> BDD.assert(ctx, true, "")
    error(e) -> BDD.assert(ctx, false, e.message)
  end
end

def malformed_reset(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  case exercise_malformed_reset()
    ok(_) -> BDD.assert(ctx, true, "")
    error(e) -> BDD.assert(ctx, false, e.message)
  end
end

def atomic_scheduler(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  case exercise_atomic_scheduler()
    ok(_) -> BDD.assert(ctx, true, "")
    error(e) -> BDD.assert(ctx, false, e.message)
  end
end

def eof_drained(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  case exercise_eof_drained()
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

def exercise_malformed() -> Result[Void]
  listener = try TCP.listen("127.0.0.1", 0)
  gate = Gate(blocked: Channel.new(1), release: Channel.new(1), cleared: Channel.new(1))
  peer = Task.spawn do Peer.malformed_retiring(listener, gate.blocked, gate.cleared) end
  result = exchange_size(TCP.local_port(listener), gate, 1, 100, 75, &malformed_requests)
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

def exercise_malformed_reset() -> Result[Void]
  listener = try TCP.listen("127.0.0.1", 0)
  gate = Gate(blocked: Channel.new(1), release: Channel.new(1), cleared: Channel.new(1))
  peer = Task.spawn do Peer.malformed_peer_reset(listener, gate.blocked, gate.cleared) end
  result = exchange_size(TCP.local_port(listener), gate, 1, 2_000, 5_000, &malformed_reset_requests)
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

def exercise_reuse() -> Result[Void]
  listener = try TCP.listen("127.0.0.1", 0)
  gate = Gate(blocked: Channel.new(1), release: Channel.new(1), cleared: Channel.new(1))
  peer = Task.spawn do Peer.reuse_after_retire(listener, gate.blocked, gate.cleared) end
  result = exchange_size(TCP.local_port(listener), gate, 2, 2_000, 5_000, &reuse_requests)
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

def exchange_size(
  port: Int,
  gate: Gate,
  size: Int,
  wait_ms: Int,
  idle_ms: Int,
  flow: Fn[Origin.Origin, String, Gate, Int, Result[Void]],
) -> Result[Void]
  base = "http://127.0.0.1:#{port}"
  cache: ATS[String, Dial.Resolved] = ATS.new()
  dialer = Dial.Dialer(
    own: false,
    resolver: ->(_host) { ok(["127.0.0.1"]) },
    cache: cache,
    cache_ms: 0,
    public_only: false,
  )

  config = Origin.Config(
    origin: base,
    dialer: dialer,
    options: HTTP.ClientOptions(),
    size: size,
    wait_ms: wait_ms,
    idle_ms: idle_ms,
    send: some(->(socket, bytes, queued) { gated_send(socket, bytes, queued, gate) }),
  )

  origin = Origin.start(config)
  deadline = Time.monotonic_ms() + 700
  result = flow.call(origin, base, gate, deadline)
  _ = Origin.close(origin, 0)
  result
end

def malformed_requests(origin: Origin.Origin, base: String, gate: Gate, deadline: Int) -> Result[Void]
  outcome = send_request(origin, base, "POST", "/malformed", ("x" * 20_000).bytes, deadline)
  case outcome
    error(e) if e.is_a?("http_client.http2.protocol") -> nil
    error(e) -> return error("expected protocol error, got #{e.kind}: #{e.message}")
    ok(_) -> return error("expected a malformed response error")
  end

  try check_pool_timeout(origin, base)
  try release_writer(gate, deadline)
  following = try send_request(origin, base, "GET", "/after", "".bytes, Time.monotonic_ms() + 2_000)
  return error("expected response status 200") if following.status != 200
  ok()
end

# A peer reset for a malformed stream releases the slot and suppresses the
# queued local reset, so the next call reuses the session with no local RST on
# the wire.
def malformed_reset_requests(origin: Origin.Origin, base: String, gate: Gate, deadline: Int) -> Result[Void]
  outcome = send_request(origin, base, "POST", "/malformed", ("x" * 20_000).bytes, deadline)
  case outcome
    error(e) if e.is_a?("http_client.http2.protocol") -> nil
    error(e) -> return error("expected protocol error, got #{e.kind}: #{e.message}")
    ok(_) -> return error("expected a malformed response error")
  end

  try release_writer(gate, deadline)
  following = try send_request(origin, base, "GET", "/after", "".bytes, Time.monotonic_ms() + 2_000)
  return error("expected response status 200") if following.status != 200
  ok()
end

# A closed reader channel that already holds the final suffix, with the
# session already holding the split prefix and the writer blocked: advancing
# through the shared post-pull step must drain the suffix into a complete
# buffered response instead of failing at EOF. Removing the drain guard turns
# this into a closed-connection error.
def exercise_eof_drained() -> Result[Void]
  wire = Frame.encode(0, 1, 1, "complete".bytes)
  split = wire.size - 4
  prefix = wire.slice(0, split)
  suffix = wire.drop(split)
  incoming: Channel[Bytes] = Channel.new(8)
  try incoming.send(suffix, 5_000)
  incoming.close
  blocked: Channel[Connection.Write] = Channel.new(8)
  try blocked.send(Connection.Write(bytes: "x".bytes), 5_000)
  done: Channel[Result[Connection.Response]] = Channel.new(1)
  origin = stub_origin(done)
  state = try eof_state(origin, incoming, prefix, blocked)
  waiting = try Session.resume(state)
  drained = try Connection.pull(waiting.conn.unwrap!, Time.monotonic_ms() + 5_000)
  finished = try Session.resume(waiting.with(conn: some(drained)))
  _ = finished
  reported = done.recv(2_000)
  Task.cancel(origin.ref.task)
  _ = Task.await(origin.ref.task)
  case reported
    error(e) -> error("drain guard removed: no completion with queued suffix (#{e.message})")
    ok(outcome) ->
      case outcome
        error(e) -> error("drain guard removed: #{e.kind}: #{e.message}")
        ok(response) ->
          return error("expected response status 413") if response.status != 413
          return error("the final response body was lost") if response.body != "complete".bytes
          ok()
      end
  end
end

def stub_origin(done: Channel[Result[Connection.Response]]) -> Origin.Origin
  cache: ATS[String, Dial.Resolved] = ATS.new()
  dialer = Dial.Dialer(
    own: false,
    resolver: ->(_host) { ok(["127.0.0.1"]) },
    cache: cache,
    cache_ms: 0,
    public_only: false,
  )

  ref = Actor.start(
    Actor.Behaviour(
      init: -> {
        Origin.State(
          config: Origin.Config(
            origin: "http://127.0.0.1:1",
            dialer: dialer,
            options: HTTP.ClientOptions(),
            size: 1,
            wait_ms: 5_000,
            idle_ms: 5_000,
          ),
        )
      },
      handle: ->(state, msg) { stub_handle(state, msg, done) },
      terminate: none,
      timeout: none,
    ),
    Actor.Options(capacity: 256),
  )

  Origin.Origin(ref: ref, wait_ms: 5_000)
end

def stub_handle(
  state: Origin.State,
  msg: Messages.Origin,
  done: Channel[Result[Connection.Response]],
) -> Actor.Step[Origin.State]
  case msg
    Messages.Origin.Complete(_id, _key, result, _seats, _retiring, _draining) ->
      _ = done.send(result, 5_000)
      Actor.continue(state)
    _ -> Actor.continue(state)
  end
end

def eof_state(
  origin: Origin.Origin,
  incoming: Channel[Bytes],
  prefix: Bytes,
  blocked: Channel[Connection.Write],
) -> Result[Session.State]
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
    owner: origin.ref.address,
    origin: "http://127.0.0.1:1",
    dialer: dialer,
    options: HTTP.ClientOptions(),
    connect_deadline: Time.monotonic_ms() + 5_000,
    timeout_kind: "http_client.timeout.connect",
    send: none,
  )

  reader = Task.spawn do ok() end
  _ = Task.await(reader)
  blocked_conn = Connection.Session(
    socket: try eof_socket(),
    incoming: incoming,
    reader: reader,
    decoder: Hpack.decoder(),
    buffer: prefix,
    next_stream: 3,
    send_credit: 65_535,
    receive_credit: 65_535,
    initial_window: 65_535,
    frame_size: 16_384,
    stream_limit: 100,
    last_stream: 0x7fffffff,
    draining: false,
    read_only: false,
    write_error: none,
    writer: some(blocked),
  )

  target = Url.resolve("http://127.0.0.1:1", "/early").unwrap!
  call = Messages.Call(
    request: Connection.Request(
      method: "POST",
      target: target,
      headers: [],
      body: ("x" * 20_000).bytes,
      read_timeout_ms: 1_000,
      body_idle_ms: 1_000,
      deadline: Time.monotonic_ms() + 5_000,
      max_body_bytes: 100_000,
    ),
    connect_ms: 1_000,
    caller: Task.current,
    reply: Channel.new(1),
    admission_deadline: Time.monotonic_ms() + 5_000,
  )

  flight = Session.Flight(
    call: call,
    stream: Connection.Stream(id: 1, send_credit: 65_535, status: 413),
    deadline: Time.monotonic_ms() + 5_000,
    local_done: false,
  )

  ok(
    Session.State(config: config, conn: some(blocked_conn)).with(
      active: Session.State(config: config).active.put(1, flight),
      order: Session.State(config: config).order.push(1),
    ),
  )
end

def eof_socket() -> Result[TCP.Socket]
  listener = try TCP.listen("127.0.0.1", 0)
  port = TCP.local_port(listener)
  connector = Task.spawn do TCP.connect("127.0.0.1", port, 5_000) end
  server = try TCP.accept(listener, 5_000)
  client = case Task.await(connector, 5_000)
    Await.Done(inner) -> inner
    Await.TimedOut -> error("the connector did not finish")
  end

  socket = client.unwrap!
  TCP.close(server)
  TCP.close_listener(listener)
  ok(socket)
end

def reuse_requests(origin: Origin.Origin, base: String, gate: Gate, deadline: Int) -> Result[Void]
  post = try send_request(origin, base, "POST", "/early", ("x" * 20_000).bytes, deadline)
  return error("expected an early 413") if post.status != 413
  return error("the early response body was lost") if post.body != "complete".bytes
  try release_writer(gate, deadline)
  following = try send_request(origin, base, "GET", "/after", "".bytes, Time.monotonic_ms() + 2_000)
  return error("expected response status 200") if following.status != 200
  ok()
end

# An atomic completion carries its capacity change together with the freed
# slot, so a queued call reuses its session. Sending the capacity first and
# the completion after (the old split notification order) dials an extra
# session even though the queued call ends up reusing the first one, which is
# the unnecessary socket this covers. A fake session drives the origin actor
# boundary directly, so the ordering is deterministic with channel gates and
# no wire or sleep guesses.
def exercise_atomic_scheduler() -> Result[Void]
  try split_order_dials_extra()
  atomic_order_reuses()
end

def split_order_dials_extra() -> Result[Void]
  spawned: Channel[Bool] = Channel.new(8)
  opened: Channel[Int] = Channel.new(8)
  origin = start_fake_origin(2, spawned, opened)
  first_ids: Channel[Int] = Channel.new(1)
  first = Task.spawn do
    _ = first_ids.send(Task.current.id, 5_000)
    send_fake_request(origin, "/one")
  end

  first_id = try first_ids.recv(5_000)
  _ = try spawned.recv(5_000)
  try notify_capacity(origin, 1, 2, 0, false)
  opened_first = try opened.recv(5_000)
  return error("split first was not assigned") if opened_first != first_id
  try notify_capacity(origin, 1, 1, 1, false)
  second_ids: Channel[Int] = Channel.new(1)
  second = Task.spawn do
    _ = second_ids.send(Task.current.id, 5_000)
    send_fake_request(origin, "/two")
  end

  second_id = try second_ids.recv(5_000)
  case spawned.recv(5_000)
    ok(_) -> nil
    error(e) -> return error("split order did not dial extra: #{e.message}")
  end

  try notify_complete(origin, 1, first_id, 1, 1, false)
  opened_second = try opened.recv(5_000)
  return error("split second did not reuse its session") if opened_second != second_id
  try notify_complete(origin, 1, second_id, 1, 1, false)
  first_result = try await_call(first, "split first")
  second_result = try await_call(second, "split second")
  return error("split first failed") if first_result.status != 200
  return error("split second failed") if second_result.status != 200
  case spawned.recv(100)
    ok(_) -> return error("split order dialled a third session")
    error(_) -> nil
  end

  _ = Origin.close(origin, 0)
  ok()
end

def atomic_order_reuses() -> Result[Void]
  spawned: Channel[Bool] = Channel.new(8)
  opened: Channel[Int] = Channel.new(8)
  origin = start_fake_origin(2, spawned, opened)
  first_ids: Channel[Int] = Channel.new(1)
  first = Task.spawn do
    _ = first_ids.send(Task.current.id, 5_000)
    send_fake_request(origin, "/one")
  end

  first_id = try first_ids.recv(5_000)
  _ = try spawned.recv(5_000)
  try notify_capacity(origin, 1, 2, 0, false)
  opened_first = try opened.recv(5_000)
  return error("atomic first was not assigned") if opened_first != first_id
  try notify_complete(origin, 1, first_id, 1, 1, false)
  second_ids: Channel[Int] = Channel.new(1)
  second = Task.spawn do
    _ = second_ids.send(Task.current.id, 5_000)
    send_fake_request(origin, "/two")
  end

  second_id = try second_ids.recv(5_000)
  opened_second = try opened.recv(5_000)
  return error("atomic second did not reuse its session") if opened_second != second_id
  try notify_complete(origin, 1, second_id, 1, 1, false)
  first_result = try await_call(first, "atomic first")
  second_result = try await_call(second, "atomic second")
  return error("atomic first failed") if first_result.status != 200
  return error("atomic second failed") if second_result.status != 200
  case spawned.recv(100)
    ok(_) -> return error("atomic order dialled an unnecessary session")
    error(_) -> nil
  end

  _ = Origin.close(origin, 0)
  ok()
end

def start_fake_origin(size: Int, spawned: Channel[Bool], opened: Channel[Int]) -> Origin.Origin
  cache: ATS[String, Dial.Resolved] = ATS.new()
  dialer = Dial.Dialer(
    own: false,
    resolver: ->(_host) { ok(["127.0.0.1"]) },
    cache: cache,
    cache_ms: 0,
    public_only: false,
  )

  config = Origin.Config(
    origin: "http://127.0.0.1:1",
    dialer: dialer,
    options: HTTP.ClientOptions(),
    size: size,
    wait_ms: 5_000,
    idle_ms: 60_000,
    spawn: some(->(cfg) { fake_start(spawned, opened, cfg) }),
  )

  Origin.start(config)
end

def fake_start(
  spawned: Channel[Bool],
  opened: Channel[Int],
  cfg: Session.Config,
) -> Actor.Ref[Session.State, Session.Msg]
  _ = spawned.send(true, 5_000)
  Actor.start(
    Actor.Behaviour(
      init: -> { Session.State(config: cfg) },
      handle: ->(state, msg) { fake_handle(state, msg, opened) },
      terminate: none,
      timeout: none,
    ),
    Actor.Options(capacity: 256),
  )
end

def fake_handle(state: Session.State, msg: Session.Msg, opened: Channel[Int]) -> Actor.Step[Session.State]
  case msg
    Session.Msg.Open(call, _block) ->
      _ = opened.send(call.caller.id, 5_000)
      Actor.continue(state)
    Session.Msg.Stop -> Actor.done(state)
    _ -> Actor.continue(state)
  end
end

def send_fake_request(origin: Origin.Origin, path: String) -> Result[Connection.Response]
  target = try Url.resolve("http://127.0.0.1:1", path)
  req = Connection.Request(
    method: "GET",
    target: target,
    headers: [],
    body: "".bytes,
    read_timeout_ms: 1_000,
    body_idle_ms: 1_000,
    deadline: Time.monotonic_ms() + 5_000,
    max_body_bytes: 1_024,
  )

  Origin.request(origin, req, 1_000)
end

def notify_capacity(origin: Origin.Origin, id: Int, seats: Int, retiring: Int, draining: Bool) -> Result[Void]
  try Actor.cast(origin.ref.address, Messages.Origin.Capacity(id, seats, retiring, draining), 5_000)
  ok()
end

def notify_complete(
  origin: Origin.Origin,
  id: Int,
  key: Int,
  seats: Int,
  retiring: Int,
  draining: Bool,
) -> Result[Void]
  done = ok(Connection.Response(status: 200, headers: [], body: "ok".bytes))
  try Actor.cast(origin.ref.address, Messages.Origin.Complete(id, key, done, seats, retiring, draining), 5_000)
  ok()
end

def await_call(task: Task[Result[Connection.Response]], what: String) -> Result[Connection.Response]
  case Task.await(task, 5_000)
    Await.Done(inner) ->
      case inner
        error(e) -> error("#{what}: #{e.kind}: #{e.message}")
        ok(response) -> ok(response)
      end

    Await.TimedOut -> error("#{what} timed out")
  end
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
