import Actor from "std/actor"
import Connection from "connection"
import Dial from "../dial"
import Frame from "frame"
import HTTP from "std/http"
import Messages from "messages"

struct Config
  id: Int
  owner: Address[Messages.Origin]
  dialer: Dial.Dialer
  options: HTTP.ClientOptions
  origin: String
  connect_deadline: Int
  timeout_kind: String
end

enum Msg
  Boot
  Open(Messages.Call, Bytes)
  Cancel(Int)
  Readable
  Written(Result[Void])
  ReaderDown
  Drain
  Stop
end

struct Flight
  call: Messages.Call
  stream: Connection.Stream
  deadline: Int
end

enum Phase
  AwaitingSettings
  Ready
  Draining
end

struct State
  config: Config
  conn: Optional[Connection.Session] = none
  writer: Optional[Task[Result[Void]]] = none
  active: Map[Int, Flight] = {}
  order: List[Int] = []
  pending: List[OpenCall] = []
  receiving: Int = 0
  resets: List[Reset] = []
  discarded: Optional[Connection.Stream] = none
  advertised: Int = -1
  phase: Phase = Phase.AwaitingSettings
end

struct Reset
  stream: Int
  code: Int = 8
end

struct OpenCall
  call: Messages.Call
  block: Bytes
end

def start(config: Config) -> Actor.Ref[State, Msg]
  behaviour = Actor.Behaviour(
    init: -> { State(config: config) },
    handle: &handle,
    terminate: some(&terminate),
    timeout: some(Actor.Timeout(after_ms: &next_wait, handle: &advance)),
  )

  Actor.start(behaviour, Actor.Options(capacity: 256))
end

private

WRITE_TIMEOUT_MS = 30_000

def handle(state: State, message: Msg) -> Actor.Step[State]
  current = state
  case message
    Msg.Boot ->
      inbox: Channel[Msg] = Actor.inbox
      case Dial.open_h2(
        state.config.dialer,
        state.config.origin,
        state.config.options,
        state.config.connect_deadline,
        ->(socket, limit) { handshake(socket, limit, inbox) },
      )
        ok(conn) ->
          out: Channel[Connection.Write] = Channel.new(16)
          writer = Task.spawn do write_loop(conn.socket, out, inbox) end
          Task.monitor(conn.reader, inbox) do |_down| Msg.ReaderDown end
          Task.monitor(writer, inbox) do |_down| Msg.Written(error("HTTP/2 writer ended", kind: "net.closed")) end
          current = state.with(conn: some(conn.with(writer: some(out))), writer: some(writer), phase: Phase.Ready)
        error(e) ->
          failure = connect_error(state.config, e)
          notify(state.config, Messages.Origin.Complete(state.config.id, 0, failure))
          return Actor.done(state)
      end

    Msg.Open(call, block) -> current = state.with(pending: state.pending.push(OpenCall(call: call, block: block)))
    Msg.Cancel(key) -> current = cancel(state, key)
    Msg.Written(error(e)) ->
      if state.conn.some?
        conn = state.conn.unwrap!
        if conn.write_error.none?
          current = state.with(conn: some(conn.with(write_error: some(e))))
        end
      end

    Msg.ReaderDown ->
      if state.conn.some?
        state.conn.unwrap!.incoming.close
      end

    Msg.Drain -> current = state.with(phase: Phase.Draining)
    Msg.Stop -> return Actor.done(fail_all(state, client_closed()))
    _ -> nil
  end

  advance(current)
end

def advance(state: State) -> Actor.Step[State]
  return Actor.continue(state) if state.conn.none?
  current = expire(state)
  case step(current)
    ok(updated) ->
      advertised = publish(updated)
      if advertised.phase == Phase.Draining and advertised.active.empty? and advertised.pending.empty?
        return Actor.done(advertised)
      end

      Actor.continue(advertised)
    error(e) -> Actor.done(fail_all(current, normalize(e)))
  end
end

def next_wait(state: State) -> Optional[Int]
  return none if state.conn.none?
  conn = state.conn.unwrap!
  return some(0) if readable?(conn) or writable?(state, conn)

  limit = 3_600_000
  now = Time.monotonic_ms()
  for flight in state.active.values
    limit = [limit, flight.deadline - now].min.unwrap!
  end

  some([limit, 0].max.unwrap!)
end

def readable?(conn: Connection.Session) -> Bool
  return not conn.incoming.empty? if not Frame.pending?(conn.buffer)
  not defer?(conn, conn.buffer[3])
end

def defer?(conn: Connection.Session, kind: Int) -> Bool
  conn.write_error.none? and not conn.writer.unwrap!.empty? and (kind == 0 or kind == 4 or kind == 6)
end

def writable?(state: State, conn: Connection.Session) -> Bool
  return false if conn.write_error.some? or not conn.writer.unwrap!.empty?
  return true if not state.pending.empty? or not state.resets.empty?

  for flight in state.active.values
    if Connection.can_send?(Connection.Progress(session: conn, stream: flight.stream), flight.call.request.body.size)
      return true
    end
  end

  false
end

def step(state: State) -> Result[State]
  conn = state.conn.unwrap!
  ready = try Connection.pull(conn, Time.monotonic_ms() + 1_000)
  current = state.with(conn: some(ready))
  case try Frame.parse(ready.buffer)
    some(parsed) ->
      return ok(current) if defer?(ready, parsed.frame.kind)
      return received(current.with(conn: some(ready.with(buffer: parsed.rest))), parsed.frame)
    none -> nil
  end

  return error(ready.write_error.unwrap!) if ready.write_error.some?

  return error("the HTTP/2 connection closed", kind: "http_client.network") if ready.incoming.closed?

  if not current.resets.empty? and ready.writer.unwrap!.empty?
    reset = current.resets.first
    try Connection.reset(ready, reset.stream, reset.code, Time.monotonic_ms() + 1_000)
    return ok(current.with(resets: current.resets.drop(1)))
  end

  return admit(current) if not current.pending.empty?

  upload(current)
end

def admit(state: State) -> Result[State]
  conn = state.conn.unwrap!
  entry = state.pending.first
  if state.phase == Phase.Draining or not Connection.reusable?(conn)
    complete(state, entry.call.caller.id, unsent())
    return ok(state.with(pending: state.pending.drop(1)))
  end

  if state.active.size >= conn.stream_limit
    updated = publish(state)
    complete(updated, entry.call.caller.id, error("HTTP/2 session has no stream capacity", kind: "http2.capacity"))
    return ok(updated.with(pending: updated.pending.drop(1)))
  end

  if entry.call.request.deadline <= Time.monotonic_ms()
    complete(
      state,
      entry.call.caller.id,
      error("http_client: the request timed out", kind: "http_client.timeout.request"),
    )

    return ok(state.with(pending: state.pending.drop(1)))
  end

  return ok(state) if not conn.writer.unwrap!.empty?
  deadline = [entry.call.request.deadline, Time.monotonic_ms() + entry.call.request.read_timeout_ms].min.unwrap!
  opened = try Connection.open_stream(conn, entry.call.request, entry.block, deadline)
  id = opened.stream.id
  flight = Flight(call: entry.call, stream: opened.stream, deadline: deadline)
  ok(
    state.with(
      conn: some(opened.session),
      active: state.active.put(id, flight),
      order: state.order.push(id),
      pending: state.pending.drop(1),
    ),
  )
end

def upload(state: State) -> Result[State]
  conn = state.conn.unwrap!
  return ok(state) if not conn.writer.unwrap!.empty?
  for id in state.order
    flight = state.active.get(id).unwrap!
    progress = Connection.Progress(session: conn, stream: flight.stream)
    next if not Connection.can_send?(progress, flight.call.request.body.size)
    sent = try Connection.send_piece(progress, flight.call.request.body, flight.deadline)
    ordered = state.order.select { |key| key != id }.push(id)
    return ok(
      state.with(
        conn: some(sent.session),
        active: state.active.put(id, flight.with(stream: sent.stream)),
        order: ordered,
      ),
    )
  end

  ok(state)
end

def received(state: State, frame: Frame.Frame) -> Result[State]
  if state.receiving != 0 and (frame.kind != 9 or frame.stream != state.receiving)
    return Frame.invalid("interrupted header block")
  end

  if frame.stream == 0 or frame.kind == 2 or frame.kind == 4 or frame.kind == 6 or frame.kind == 7
    return received_control(state, frame)
  end

  case state.active.get(frame.stream)
    some(flight) -> received_stream(state, flight, frame)
    none -> received_inactive(state, frame)
  end
end

def received_control(state: State, frame: Frame.Frame) -> Result[State]
  conn = state.conn.unwrap!
  changed = try Connection.dispatch(conn, frame, Time.monotonic_ms() + 1_000)
  current = state.with(conn: some(changed))
  if frame.kind == 4 and frame.flags.bit_and(1) == 0
    current = try update_windows(current, frame.payload, conn.initial_window)
  end

  if changed.draining
    for id in current.active.keys
      if id > changed.last_stream
        current = finish(current, id, network("the peer closed the HTTP/2 stream"))
      end
    end
  end

  ok(current)
end

def update_windows(state: State, payload: Bytes, previous: Int) -> Result[State]
  current = state
  window = previous
  for index in 0...(payload.size / 6)
    at = index * 6
    next if payload[at] != 0 or payload[at + 1] != 4
    value = Frame.u32(payload, at + 2)
    delta = value - window
    window = value
    for id in current.active.keys
      flight = current.active.get(id).unwrap!
      credit = flight.stream.send_credit + delta
      return Frame.invalid("stream window overflow") if credit > Frame.MAX_WINDOW
      current = current.with(
        active: current.active.put(id, flight.with(stream: flight.stream.with(send_credit: credit))),
      )
    end
  end

  ok(current)
end

def received_stream(state: State, flight: Flight, frame: Frame.Frame) -> Result[State]
  if frame.kind == 3
    return Frame.invalid("invalid rst_stream") if frame.payload.size != 4
    return ok(finish(state, frame.stream, network("the peer reset the HTTP/2 stream")))
  end

  progress = Connection.Progress(session: state.conn.unwrap!, stream: flight.stream)
  outcome = Connection.dispatch_stream(progress, frame, flight.call.request, flight.deadline)
  case outcome
    error(e) if e.is_a?("http_client.too_large") ->
      discarded = try Connection.dispatch_closed(progress.session, frame, flight.stream, Time.monotonic_ms() + 1_000)
      return ok(abort_stream(state.with(conn: some(discarded.session)), flight, error(e)))
    error(e) -> return error(e)
    ok(_) -> nil
  end

  changed = outcome.unwrap!
  stream = changed.stream
  current = state.with(conn: some(changed.session), receiving: continued(stream))
  if not Connection.length_valid?(stream, flight.call.request.method)
    failed: Result[Connection.Response] = Frame.invalid("content-length does not match response body")
    return ok(abort_stream(current, flight.with(stream: stream), failed, code: 1))
  end

  if stream.ended
    if stream.phase == Connection.StreamPhase.HalfClosedRemote and changed.session.write_error.none?
      current = current.with(resets: current.resets.push(Reset(stream: stream.id)))
    end

    return ok(finish(current, stream.id, ok(Connection.response(stream))))
  end

  deadline = flight.deadline
  req = flight.call.request
  if stream.status > 0 and (flight.stream.status == 0 or stream.received > flight.stream.received)
    deadline = req.deadline
    if req.body_idle_ms > 0
      deadline = [deadline, Time.monotonic_ms() + req.body_idle_ms].min.unwrap!
    end
  end

  ok(current.with(active: current.active.put(stream.id, flight.with(stream: stream, deadline: deadline))))
end

def received_inactive(state: State, frame: Frame.Frame) -> Result[State]
  conn = state.conn.unwrap!
  if frame.stream >= conn.next_stream or frame.stream % 2 == 0
    return Frame.invalid("unexpected frame on idle stream") if frame.kind <= 9
    return ok(state)
  end

  stream = state.discarded.unwrap_or(Connection.Stream(id: frame.stream, send_credit: 0))
  progress = try Connection.dispatch_closed(conn, frame, stream, Time.monotonic_ms() + 1_000)
  discarded: Optional[Connection.Stream] = none
  if progress.stream.continuing
    discarded = some(progress.stream)
  end

  ok(state.with(conn: some(progress.session), receiving: continued(progress.stream), discarded: discarded))
end

def continued(stream: Connection.Stream) -> Int
  return stream.id if stream.continuing
  0
end

def finish(state: State, id: Int, result: Result[Connection.Response]) -> State
  flight = state.active.get(id).unwrap!
  complete(state, flight.call.caller.id, result)
  state.with(active: state.active.delete(id), order: state.order.select { |key| key != id })
end

def cancel(state: State, key: Int) -> State
  current = state.with(pending: state.pending.select { |entry| entry.call.caller.id != key })
  if current.pending.size != state.pending.size
    complete(state, key, client_closed())
    return current
  end

  for flight in state.active.values
    return abort_stream(current, flight, client_closed()) if flight.call.caller.id == key
  end

  current
end

def expire(state: State) -> State
  current = state
  now = Time.monotonic_ms()
  for flight in state.active.values
    if flight.deadline <= now
      kind = "http_client.timeout.read"
      if flight.deadline == flight.call.request.deadline
        kind = "http_client.timeout.request"
      end

      current = abort_stream(current, flight, error("http_client: the request timed out", kind: kind))
    end
  end

  current
end

def abort_stream(state: State, flight: Flight, reason: Result[Connection.Response], code: Int = 8) -> State
  s = flight.stream
  current = state.with(resets: state.resets.push(Reset(stream: s.id, code: code)))
  if s.continuing
    current = current.with(discarded: some(s.with(parts: [], phase: Connection.StreamPhase.Closed)))
  end

  finish(current, s.id, reason)
end

def publish(state: State) -> State
  conn = state.conn.unwrap!
  draining = state.phase == Phase.Draining or not Connection.reusable?(conn)
  capacity = [conn.stream_limit, 100].min.unwrap!
  if draining
    capacity = 0
  end

  if state.advertised != capacity or draining != (state.phase == Phase.Draining)
    notify(state.config, Messages.Origin.Capacity(state.config.id, capacity, draining))
  end

  return state.with(advertised: capacity, phase: Phase.Draining) if draining
  state.with(advertised: capacity)
end

def fail_all(state: State, reason: Result[Connection.Response], code: Int = 8) -> State
  for flight in state.active.values
    complete(state, flight.call.caller.id, reason)
  end

  for entry in state.pending
    complete(state, entry.call.caller.id, unsent())
  end

  state.with(active: {}, order: [], pending: [])
end

def complete(state: State, key: Int, result: Result[Connection.Response]) -> Void
  notify(state.config, Messages.Origin.Complete(state.config.id, key, result))
end

def notify(config: Config, event: Messages.Origin) -> Void
  _ = Actor.cast(config.owner, event, 1_000)
end

def handshake(socket: TCP.Socket, deadline: Int, inbox: Channel[Msg]) -> Result[Connection.Session]
  incoming: Channel[Bytes] = Channel.new(2)
  reader = Task.spawn do read_loop(socket, incoming, inbox) end
  opened = Connection.start(socket, incoming, reader, deadline)
  if not opened.ok?
    close_reader(socket, incoming, reader)
  end

  opened
end

def read_loop(socket: TCP.Socket, incoming: Channel[Bytes], inbox: Channel[Msg]) -> Result[Void]
  while not incoming.closed?
    case TCP.recv_bytes(socket, Frame.MAX_PAYLOAD)
      ok(bytes) if not bytes.empty? ->
        break if not incoming.send(bytes, 3_600_000).ok?
        _ = inbox.send(Msg.Readable, 0)
      _ -> break
    end
  end

  incoming.close
  _ = inbox.send(Msg.Readable, 0)
  ok()
end

def write_loop(socket: TCP.Socket, out: Channel[Connection.Write], inbox: Channel[Msg]) -> Result[Void]
  while not out.closed?
    case out.recv(3_600_000)
      ok(item) ->
        sent = TCP.send_bytes(socket, item.bytes, WRITE_TIMEOUT_MS)
        try inbox.send(Msg.Written(sent), 1_000)
        break if not sent.ok?
      error(e) if e.is_a?("channel.closed") -> break
      error(_) -> nil
    end
  end

  ok()
end

def terminate(state: State) -> Void
  case state.conn
    some(conn) ->
      conn.writer.unwrap!.close
      close_reader(conn.socket, conn.incoming, conn.reader)
      writer = state.writer.unwrap!
      Task.cancel(writer)
      _ = Task.await(writer)
    none -> nil
  end
end

def close_reader(socket: TCP.Socket, incoming: Channel[Bytes], reader: Task[Result[Void]]) -> Void
  incoming.close
  TCP.close(socket)
  Task.cancel(reader)
  _ = Task.await(reader)
end

def connect_error(config: Config, e: Error) -> Result[Connection.Response]
  return error(e) if e.is_a?("http_client")
  return error("http_client: HTTP/2 connect timed out", kind: config.timeout_kind, cause: e) if e.is_a?("net.timeout")

  network(e.message)
end

def normalize(e: Error) -> Result[Connection.Response]
  return error(e) if e.is_a?("http_client")
  return error("http_client: HTTP/2 header decoding failed", kind: "http_client.http2.compression") if e.is_a?("hpack")

  network(e.message)
end

def network(message: String) -> Result[Connection.Response] = error(message, kind: "http_client.network")

def unsent() -> Result[Connection.Response]
  error("HTTP/2 session closed before request headers", kind: "http2.unsent")
end

def client_closed() -> Result[Connection.Response]
  error("http_client: the client is closed", kind: "http_client.closed")
end
