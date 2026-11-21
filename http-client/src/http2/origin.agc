import Actor from "std/actor"
import Connection from "connection"
import Dial from "../dial"
import Headers from "headers"
import HTTP from "std/http"
import Messages from "messages"
import Session from "session"

struct Config
  origin: String
  dialer: Dial.Dialer
  options: HTTP.ClientOptions
  size: Int
  wait_ms: Int
  idle_ms: Int
  send: Optional[Fn[TCP.Socket, Bytes, Result[Void]]] = none
end

struct Pending
  call: Messages.Call
  block: Bytes
  sequence: Int
  session: Int = 0
end

struct Peer
  ref: Actor.Ref[Session.State, Session.Msg]
  starting: Int
  seats: Int = 0
  used: Int = 0
  idle_since: Int = 0
  draining: Bool = false
end

struct State
  config: Config
  queue: List[Int] = []
  calls: Map[Int, Pending] = {}
  peers: Map[Int, Peer] = {}
  next_id: Int = 1
  next_sequence: Int = 0
  closing: Optional[Int] = none
end

struct Origin
  ref: Actor.Ref[State, Messages.Origin]
  wait_ms: Int
end

def start(config: Config) -> Origin
  behaviour = Actor.Behaviour(
    init: -> { State(config: config) },
    handle: &handle,
    terminate: some(&terminate),
    timeout: some(Actor.Timeout(after_ms: &next_wait, handle: &advance)),
  )

  Origin(ref: Actor.start(behaviour, Actor.Options(capacity: 1_024)), wait_ms: config.wait_ms)
end

def request(origin: Origin, req: Connection.Request, connect_ms: Int) -> Result[Connection.Response]
  now = Time.monotonic_ms()
  return expired("http_client.timeout.request") if now >= req.deadline
  reply: Channel[Result[Connection.Response]] = Channel.new(1)
  deadline = [req.deadline, now + origin.wait_ms].min.unwrap!
  call = Messages.Call(
    request: req,
    connect_ms: connect_ms,
    caller: Task.current,
    reply: reply,
    admission_deadline: deadline,
  )

  if not Actor.cast(origin.ref.address, Messages.Origin.Submit(call), deadline - now).ok?
    return closed_error() if not live?(origin)
    return waiting_error(call)
  end

  watcher = Task.spawn do close_on_exit(origin, reply) end
  result = reply.recv([req.deadline - Time.monotonic_ms(), 0].max.unwrap!)
  reply.close
  Task.cancel(watcher)
  _ = Task.await(watcher)
  case result
    ok(response) -> response
    error(e) if e.is_a?("channel.closed") -> closed_error()
    error(_) -> expired("http_client.timeout.request")
  end
end

def live?(origin: Origin) -> Bool = not origin.ref.inbox.closed?

def close(origin: Origin, drain_ms: Int) -> Result[Void]
  _ = Actor.cast(origin.ref.address, Messages.Origin.Close(Time.monotonic_ms() + drain_ms), 1_000)
  case Task.await(origin.ref.task, drain_ms + 2_000)
    Await.Done(result) -> result
    Await.TimedOut ->
      Task.cancel(origin.ref.task)
      Task.await(origin.ref.task)
  end
end

private

def close_on_exit(origin: Origin, reply: Channel[Result[Connection.Response]]) -> Result[Void]
  _ = Task.await(origin.ref.task)
  reply.close
  ok()
end

def waiting_error(call: Messages.Call) -> Result[Connection.Response]
  return expired("http_client.timeout.request") if call.admission_deadline == call.request.deadline
  expired("http_client.timeout.pool")
end

def handle(state: State, msg: Messages.Origin) -> Actor.Step[State]
  current = state
  case msg
    Messages.Origin.Submit(call) -> current = submit(state, call)
    Messages.Origin.CallerDown(key) -> current = cancel(state, key)
    Messages.Origin.Capacity(id, seats, draining) ->
      case state.peers.get(id)
        some(peer) ->
          idle_since = peer.idle_since
          if peer.starting != 0
            idle_since = Time.monotonic_ms()
          end

          updated = state.with(
            peers: state.peers.put(
              id,
              peer.with(starting: 0, seats: seats, draining: draining, idle_since: idle_since),
            ),
          )

          current = updated
          if peer.starting != 0 and draining
            current = startup_drained(updated, peer.starting)
          end

        none -> nil
      end

    Messages.Origin.Complete(id, key, result) -> current = completed(state, id, key, result)
    Messages.Origin.SessionDown(id) -> current = disconnected(state, id)
    Messages.Origin.Close(deadline) -> current = begin_close(state, deadline)
  end

  advance(current)
end

def advance(state: State) -> Actor.Step[State]
  current = sweep(state)
  if current.closing.some?
    return Actor.done(current) if current.peers.empty?
    return Actor.done(force_close(current)) if Time.monotonic_ms() >= current.closing.unwrap!

    return Actor.continue(current)
  end

  Actor.continue(retire_idle(schedule(current)))
end

def retire_idle(state: State) -> State
  now = Time.monotonic_ms()
  peers = state.peers
  for id in peers.keys
    peer = peers.get(id).unwrap!
    if idle?(peer) and now - peer.idle_since >= state.config.idle_ms
      if Actor.cast(peer.ref.address, Session.Msg.Drain, 0).ok?
        peers = peers.put(id, peer.with(draining: true))
      end
    end
  end

  state.with(peers: peers)
end

def idle?(peer: Peer) -> Bool = peer.starting == 0 and peer.used == 0 and not peer.draining

def next_wait(state: State) -> Optional[Int]
  now = Time.monotonic_ms()
  return some([state.closing.unwrap! - now, 0].max.unwrap!) if state.closing.some?

  wait = 3_600_000
  for peer in state.peers.values
    if idle?(peer)
      wait = [wait, peer.idle_since + state.config.idle_ms - now].min.unwrap!
    end
  end

  for key in state.queue
    next if connecting?(state, key)
    pending = state.calls.get(key).unwrap!
    wait = [wait, pending.call.admission_deadline - now].min.unwrap!
  end

  some([wait, 0].max.unwrap!)
end

def submit(state: State, call: Messages.Call) -> State
  if state.closing.some?
    _ = Actor.reply(call.reply, closed_error())
    return state
  end

  now = Time.monotonic_ms()
  if state.queue.size >= 1_000 or call.admission_deadline <= now
    result: Result[Connection.Response] = expired("http_client.timeout.pool")
    if call.admission_deadline <= now
      result = waiting_error(call)
    end

    _ = Actor.reply(call.reply, result)
    return state
  end

  req = call.request
  if req.body.size > state.config.options.max_body_bytes
    _ = Actor.reply(call.reply, error("HTTP/2 request body exceeds its limit", kind: "argument"))
    return state
  end

  case Headers.encode(req.method, req.target, req.headers, req.body.size)
    error(e) ->
      _ = Actor.reply(call.reply, error(e))
      state
    ok(block) ->
      id = call.caller.id
      inbox: Channel[Messages.Origin] = Actor.inbox
      Task.monitor(call.caller, inbox) do |_down| Messages.Origin.CallerDown(id) end
      pending = Pending(call: call, block: block, sequence: state.next_sequence)
      state.with(
        calls: state.calls.put(id, pending),
        queue: state.queue.push(id),
        next_sequence: state.next_sequence + 1,
      )
  end
end

def schedule(state: State) -> State
  current = state
  for _ in 0...state.queue.size
    key = current.queue.first
    pending = current.calls.get(key).unwrap!
    case available(current)
      some(id) ->
        peer = current.peers.get(id).unwrap!
        sent = Actor.cast(peer.ref.address, Session.Msg.Open(pending.call, pending.block), 0)
        return current if not sent.ok?
        current = current.with(
          queue: current.queue.drop(1),
          calls: current.calls.put(key, pending.with(session: id)),
          peers: current.peers.put(id, peer.with(used: peer.used + 1)),
        )
      none ->
        return start_peer(current, pending) if may_connect?(current)
        return current
    end
  end

  current
end

def available(state: State) -> Optional[Int]
  selected = 0
  used = -1
  for id in state.peers.keys
    peer = state.peers.get(id).unwrap!
    if not peer.draining and peer.used < peer.seats and peer.used > used
      selected = id
      used = peer.used
    end
  end

  return some(selected) if selected > 0
  none
end

def may_connect?(state: State) -> Bool
  state.peers.size < state.config.size and not state.peers.values.any? { |peer| peer.starting != 0 }
end

def start_peer(state: State, pending: Pending) -> State
  id = state.next_id
  now = Time.monotonic_ms()
  deadline = [now + pending.call.connect_ms, pending.call.request.deadline].min.unwrap!
  kind = "http_client.timeout.connect"
  if deadline == pending.call.request.deadline
    kind = "http_client.timeout.request"
  end

  inbox: Channel[Messages.Origin] = Actor.inbox
  config = state.config
  ref = Session.start(
    Session.Config(
      id: id,
      owner: inbox.address,
      origin: config.origin,
      dialer: config.dialer,
      options: config.options,
      connect_deadline: deadline,
      timeout_kind: kind,
      send: config.send,
    ),
  )

  Task.monitor(ref.task, inbox) do |_down| Messages.Origin.SessionDown(id) end
  _ = Actor.cast(ref.address, Session.Msg.Boot, 0)
  state.with(next_id: id + 1, peers: state.peers.put(id, Peer(ref: ref, starting: pending.call.caller.id)))
end

def completed(state: State, id: Int, key: Int, result: Result[Connection.Response]) -> State
  case state.peers.get(id)
    none -> state
    some(peer) ->
      return reject_start(state, peer.starting, result) if key == 0

      case state.calls.get(key)
        none -> state
        some(pending) ->
          return state if pending.session != id
          next_state = state.with(
            peers: state.peers.put(id, peer.with(used: peer.used - 1, idle_since: Time.monotonic_ms())),
          )

          case result
            error(e) if e.is_a?("http2.capacity") and state.closing.none? ->
              requeue(next_state, key, pending.with(session: 0))
            error(e) if (e.is_a?("http2.unsent") or e.is_a?("http2.capacity")) and state.closing.some? ->
              reply(next_state, key, closed_error())
            error(e) if e.is_a?("http2.unsent") and not pending.call.retried and state.closing.none? ->
              retried = pending.with(session: 0, call: pending.call.with(retried: true))
              requeue(next_state, key, retried)
            error(e) if e.is_a?("http2.unsent") ->
              reply(next_state, key, error("HTTP/2 session closed", kind: "http_client.network"))
            _ -> reply(next_state, key, result)
          end
      end
  end
end

def requeue(state: State, key: Int, pending: Pending) -> State
  calls = state.calls.put(key, pending)
  queue = state.queue.push(key).sort_by { |item| calls.get(item).unwrap!.sequence }
  state.with(calls: calls, queue: queue)
end

def startup_drained(state: State, key: Int) -> State
  case state.calls.get(key)
    some(pending) if pending.session == 0 ->
      return reply(state, key, error("HTTP/2 session closed", kind: "http_client.network")) if pending.call.retried

      state.with(calls: state.calls.put(key, pending.with(call: pending.call.with(retried: true))))
    _ -> state
  end
end

def reject_start(state: State, key: Int, result: Result[Connection.Response]) -> State
  case state.calls.get(key)
    some(pending) if pending.session == 0 -> reply(state, key, result)
    _ -> state
  end
end

def disconnected(state: State, id: Int) -> State
  current = state
  for key in state.calls.keys
    item = state.calls.get(key).unwrap!
    if item.session == id
      current = reply(current, key, error("HTTP/2 session ended", kind: "http_client.network"))
    end
  end

  current.with(peers: current.peers.delete(id))
end

def cancel(state: State, key: Int) -> State
  case state.calls.get(key)
    none -> state
    some(pending) if pending.session == 0 -> reply(state, key, closed_error())
    some(pending) ->
      peer = state.peers.get(pending.session).unwrap!
      _ = Actor.cast(peer.ref.address, Session.Msg.Cancel(key), 0)
      state
  end
end

def sweep(state: State) -> State
  current = state
  now = Time.monotonic_ms()
  for key in state.queue
    pending = state.calls.get(key).unwrap!
    if pending.call.admission_deadline <= now and not connecting?(state, key)
      kind = "http_client.timeout.pool"
      if pending.call.request.deadline <= now
        kind = "http_client.timeout.request"
      end

      current = reply(current, key, expired(kind))
    end
  end

  current
end

def connecting?(state: State, key: Int) -> Bool = state.peers.values.any? { |peer| peer.starting == key }

def reply(state: State, key: Int, result: Result[Connection.Response]) -> State
  pending = state.calls.get(key).unwrap!
  _ = Actor.reply(pending.call.reply, result)
  state.with(calls: state.calls.delete(key), queue: state.queue.select { |queued| queued != key })
end

def begin_close(state: State, deadline: Int) -> State
  current = state.with(closing: some(deadline))
  for key in state.queue
    current = reply(current, key, closed_error())
  end

  for peer in state.peers.values
    _ = Actor.cast(peer.ref.address, Session.Msg.Drain, 0)
  end

  current
end

def force_close(state: State) -> State
  current = state
  for key in state.calls.keys
    current = reply(current, key, closed_error())
  end

  current
end

def terminate(state: State) -> Void
  for item in state.calls.values
    _ = Actor.reply(item.call.reply, closed_error())
  end

  for peer in state.peers.values
    _ = Actor.cast(peer.ref.address, Session.Msg.Stop, 0)
  end

  for peer in state.peers.values
    case Task.await(peer.ref.task, 500)
      Await.Done(_) -> nil
      Await.TimedOut ->
        Task.cancel(peer.ref.task)
        _ = Task.await(peer.ref.task)
    end
  end
end

def expired[T](kind: String) -> Result[T] = error("http_client: the request timed out", kind: kind)

def closed_error() -> Result[Connection.Response]
  error("http_client: the client is closed", kind: "http_client.closed")
end
