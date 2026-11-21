## The resource of an origin's pool: a `Link`, a slot for one keep-alive connection, run by a task of its own.
##
## A handle belongs to the task that opened it, and a cancel reaches every task below the one cancelled. So no request
## opens a connection: the link task does, under the pool's keeper, under the client's manager, and the request only
## borrows it. Cancelling the task that sent a request never closes a connection that another request uses later.
##
## Making a link never connects, so the wait for a pooled connection is only the wait for a free slot; the request
## that gets an empty slot asks its link task to connect.

import Dial from "dial"
import H2 from "http2/connection"
import H2Headers from "http2/headers"
import {Protocol} from "protocol"
import HTTP from "std/http"
import Pool from "pkg/pool/pool"

## The origin of a pool, the options (proxy, TLS) its connections are opened with, and how its host is resolved.
struct Origin
  url: String
  options: HTTP.ClientOptions
  dialer: Dial.Dialer
  protocol: Protocol = Protocol.Http1
end

## A connection that a request borrows, and when it expires (monotonic ms, 0 for never), from the
## `Keep-Alive: timeout=N` of the last response.
struct Held
  conn: HTTP.Connection
  expires_at: Int
end

## A link: its task, which holds the connection, and the inbox of that task, which closes when the task ends. A link
## whose task ended (a crash) answers nothing: it fails at once, and its health check tells the pool to replace it.
struct Link
  inbox: Channel[Order]
  task: Task[Result[Void]]
  protocol: Protocol = Protocol.Http1
end

## An order for the task of a link, from the request that has the link leased or from the pool's keeper.
enum Order
  Take(Channel[Optional[Held]])
  Connect(Connecting)
  Park(Held)
  Release
  Check
  Submit(H2.Submission)
  Readable
end

## A connect to the link's origin, answered on `reply`. `wait_ms` bounds the connect.
struct Connecting
  wait_ms: Int
  reply: Channel[Result[Held]]
end

## The `Pool.Spec` of an origin. The pool ends a link by cancelling its task, which closes the connection it holds.
def spec(origin: Origin, size: Int, wait_ms: Int, idle_ms: Int, health_ms: Int) -> Pool.Spec[Origin, Link]
  Pool.Spec(
    config: origin,
    init: &make,
    checkin: &check_in,
    terminate: &stop,
    ping: &ping,
    size: size,
    checkout_ms: wait_ms,
    lease_ms: 0,
    lazy: true,
    idle_ms: idle_ms,
    health_ms: health_ms,
  )
end

## The idle connection of the link, now in use, when it is still good, else none: one that expired, or that the server
## closed or wrote to while it was idle, is ended.
def take(link: Link) -> Optional[Held]
  reply: Channel[Optional[Held]] = Channel.new(1)
  return none if down?(link) or not link.inbox.send(Order.Take(reply), ORDER_MS).ok?

  reply.recv(ORDER_MS).unwrap_or(none)
end

## Has the link task connect, and waits at most `wait_ms` (and a moment for the answer). A request that stops waiting
## sends `Release`, so a connection made after it gave up is ended. An error is std/http's error of the connect.
def connect(link: Link, wait_ms: Int) -> Result[Held]
  reply: Channel[Result[Held]] = Channel.new(1)
  if down?(link) or not link.inbox.send(Order.Connect(Connecting(wait_ms: wait_ms, reply: reply)), ORDER_MS).ok?
    return error("http_client: the link is gone", kind: "net.closed")
  end

  case reply.recv(wait_ms + ANSWER_MS)
    ok(made) -> made
    error(_) if down?(link) -> error("http_client: the link is gone", kind: "net.closed")
    error(_) ->
      release(link)
      error("network: operation timed out", kind: "net.timeout")
  end
end

## Puts the connection in use back in the link, for the next request.
def park(link: Link, held: Held) -> Void
  _ = link.inbox.send(Order.Park(held), ORDER_MS)
end

## Ends the connection in use.
def release(link: Link) -> Void
  _ = link.inbox.send(Order.Release, ORDER_MS)
end

## Runs `body`, the work of a link task, in a task of its own, whose crash ends only it, and closes the inbox when it
## ends, so that the link fails at once from then on.
def guard(inbox: Channel[Order], body: Fn[Result[Void]]) -> Result[Void]
  ran = Task.await(Task.spawn do body.call() end)
  inbox.close
  ran
end

def submit(link: Link, request: H2.Request, connect_timeout_ms: Int) -> Result[H2.Response]
  reply: Channel[Result[H2.Response]] = Channel.new(1)
  left = request.deadline - Time.monotonic_ms()
  return error("http_client: the request timed out", kind: "http_client.timeout.request") if left < 1
  submission = H2.Submission(request: request, connect_timeout_ms: connect_timeout_ms, reply: reply)
  case link.inbox.send(Order.Submit(submission), left)
    ok(_) -> nil
    error(e) if e.is_a?("channel.closed") -> return error("http_client: link closed", kind: "http_client.closed")
    error(e) -> return error("http_client: the request timed out", kind: "http_client.timeout.request", cause: e)
  end

  watcher = Task.spawn do close_reply_on_exit(link, reply) end
  wait = [request.deadline - Time.monotonic_ms(), 0].max.unwrap!
  received = reply.recv(wait)
  reply.close
  Task.cancel(watcher)
  _ = Task.await(watcher)
  case received
    ok(result) -> result
    error(e) if e.is_a?("channel.closed") -> error("http_client: the client is closed", kind: "http_client.closed")
    error(_) -> error("http_client: the request timed out", kind: "http_client.timeout.request")
  end
end

private

ORDER_MS = 5_000
# How long a request waits for the answer of its link task past the time of the connect itself.
ANSWER_MS = 1_000
# The link task waits for orders in long naps, until the pool ends it.
NAP_MS = 3_600_000
WATCHER_END_MS = 1_000
STOP_MS = 1_000

# A connection that waits for the next request, with the watcher task that reads its socket meanwhile: an idle
# keep-alive connection has nothing to read, so a read that ends (the server closed it, or wrote bytes out of turn)
# marks it dead.
struct Idle
  held: Held
  watcher: Task[Result[Bytes]]
end

# What the link task holds: a connection that waits, and one that a request uses. At most one is there.
struct Slot
  idle: Optional[Idle]
  busy: Optional[Held]
end

def make(origin: Origin) -> Result[Link]
  inbox: Channel[Order] = Channel.new(8)
  task = Task.spawn do guard(inbox, -> { run(origin, inbox) }) end
  ok(Link(inbox: inbox, task: task, protocol: origin.protocol))
end

# A request that timed out or crashed may have left the connection anywhere, and a link whose task ended serves
# nothing: the error ends the link.
def check_in(link: Link, outcome: Pool.Outcome) -> Result[Void]
  return error("http_client: the link task ended") if down?(link)
  return ok() if outcome == Pool.Outcome.Done

  error("http_client: the request did not end cleanly")
end

# The keeper must not wait for a link task that is connecting, so the check is only sent.
def ping(link: Link) -> Result[Void]
  return error("http_client: the link task ended") if down?(link)

  _ = link.inbox.send(Order.Check, 0)
  ok()
end

# The guard of the link task closes the inbox when the task ends, and so does `stop`.
def down?(link: Link) -> Bool = link.inbox.closed?

# Whether the task ended within `wait_ms`. An await, not a monitor: its answer means the task is gone, so a close
# that waited for it leaves no task behind.
def ended?[R](task: Task[Result[R]], wait_ms: Int) -> Bool
  case Task.await(task, wait_ms)
    Await.Done(_) -> true
    Await.TimedOut -> false
  end
end

# The link task ends on its own once its inbox is closed, after the order in hand; one that does not within STOP_MS
# (a connect) is cancelled. Either way `stop` returns once it is gone, with its watcher.
def stop(link: Link) -> Void
  link.inbox.close
  if not ended?(link.task, STOP_MS)
    Task.cancel(link.task)
    _ = ended?(link.task, STOP_MS)
  end
end

def run(origin: Origin, inbox: Channel[Order]) -> Result[Void]
  return run_h2(origin, inbox) if origin.protocol == Protocol.Http2
  slot = Slot(idle: none, busy: none)
  open = true
  while open
    case inbox.recv(NAP_MS)
      ok(order) -> slot = obey(origin, slot, order)
      error(e) if e.is_a?("channel.closed") -> open = false
      error(_) -> nil
    end
  end

  drop_all(slot)
  ok()
end

def obey(origin: Origin, slot: Slot, order: Order) -> Slot
  case order
    Order.Take(reply) ->
      drop_all(slot.with(idle: none))
      woken = awake(slot.idle)
      _ = reply.send(woken, 0)
      Slot(idle: none, busy: woken)
    Order.Connect(connecting) ->
      drop_all(slot)
      opened = open(origin, connecting.wait_ms)
      _ = connecting.reply.send(opened, 0)
      case opened
        ok(held) -> Slot(idle: none, busy: some(held))
        error(_) -> Slot(idle: none, busy: none)
      end

    Order.Park(held) -> Slot(idle: some(watch(held)), busy: none)
    Order.Release ->
      drop_all(slot)
      Slot(idle: none, busy: none)
    Order.Check -> slot.with(idle: checked(slot.idle))
    Order.Submit(_), Order.Readable -> slot
  end
end

def open(origin: Origin, wait_ms: Int) -> Result[Held]
  conn = try Dial.connect(origin.dialer, origin.url, origin.options, wait_ms)
  ok(Held(conn: conn, expires_at: 0))
end

def watch(held: Held) -> Idle = Idle(held: held, watcher: Task.spawn do TCP.recv_bytes(held.conn.socket, 1) end)

# The watcher stops before the request has the socket: the link waits for its end, since a cancel that
# has not landed yet would let it read the first byte of the response. A watcher that ended on its own saw the socket
# close or bytes arrive: that connection is ended, never reused, and so is one whose watcher does not stop.
#
# A server may still close the connection just as the request is sent; the request then gets a network error, as
# with any client, and an idempotent one goes again.
def awake(idle: Optional[Idle]) -> Optional[Held]
  case idle
    some(waiting) ->
      Task.cancel(waiting.watcher)
      quiet = case Task.await(waiting.watcher, WATCHER_END_MS)
        Await.Done(error(e)) if e.is_a?("task.cancelled") -> true
        _ -> false
      end

      if not quiet or expired?(waiting.held)
        HTTP.finish(waiting.held.conn)
        return none
      end

      some(waiting.held)
    none -> none
  end
end

# The idle connection, or none when it died or expired.
def checked(idle: Optional[Idle]) -> Optional[Idle]
  case idle
    some(waiting) ->
      dead = ended?(waiting.watcher, 1)
      if dead or expired?(waiting.held)
        if not dead
          stop_watcher(waiting)
        end

        HTTP.finish(waiting.held.conn)
        return none
      end

      some(waiting)
    none -> none
  end
end

def expired?(held: Held) -> Bool = held.expires_at > 0 and Time.monotonic_ms() >= held.expires_at

def stop_watcher(waiting: Idle) -> Void
  Task.cancel(waiting.watcher)
  _ = ended?(waiting.watcher, WATCHER_END_MS)
end

def drop_all(slot: Slot) -> Void
  case slot.idle
    some(waiting) ->
      stop_watcher(waiting)
      HTTP.finish(waiting.held.conn)
    none -> nil
  end

  case slot.busy
    some(held) -> HTTP.finish(held.conn)
    none -> nil
  end
end

def run_h2(origin: Origin, inbox: Channel[Order]) -> Result[Void]
  session: Optional[H2.Session] = none
  while not inbox.closed?
    case inbox.recv(NAP_MS)
      ok(Order.Submit(submission)) -> session = execute_h2(origin, session, submission, inbox)
      ok(_) -> session = ready_h2(session, inbox)
      error(e) if e.is_a?("channel.closed") -> break
      error(_) -> nil
    end
  end

  case session
    some(held) -> close_h2(held)
    none -> nil
  end

  ok()
end

def ready_h2(session: Optional[H2.Session], inbox: Channel[Order]) -> Optional[H2.Session]
  case session
    none -> none
    some(held) ->
      case H2.idle(held, Time.monotonic_ms() + 1_000)
        ok(updated) if H2.reusable?(updated) ->
          if updated.control_pending
            _ = inbox.send(Order.Readable, 0)
          end

          some(updated)
        _ ->
          close_h2(held)
          none
      end
  end
end

def close_reply_on_exit(link: Link, reply: Channel[Result[H2.Response]]) -> Result[Void]
  _ = Task.await(link.task)
  reply.close
  ok()
end

def close_h2(session: H2.Session) -> Void
  stop_reader(session.socket, session.incoming, session.reader)
end

def stop_reader(socket: TCP.Socket, incoming: Channel[Bytes], reader: Task[Result[Void]]) -> Void
  incoming.close
  TCP.close(socket)
  Task.cancel(reader)
  _ = Task.await(reader)
end

def read_h2(socket: TCP.Socket, incoming: Channel[Bytes], inbox: Channel[Order]) -> Result[Void]
  while not incoming.closed?
    case TCP.recv_bytes(socket, 16_384)
      ok(bytes) if not bytes.empty? ->
        break if not incoming.send(bytes, NAP_MS).ok?
        _ = inbox.send(Order.Readable, 0)
      _ -> break
    end
  end

  incoming.close
  _ = inbox.send(Order.Readable, 0)
  ok()
end

def execute_h2(
  origin: Origin,
  session: Optional[H2.Session],
  submission: H2.Submission,
  inbox: Channel[Order],
) -> Optional[H2.Session]
  if submission.request.body.size > origin.options.max_body_bytes
    _ = submission.reply.send(error("http_client: HTTP/2 request body exceeds its limit", kind: "argument"), 0)

    return session
  end

  request = submission.request
  case H2Headers.encode(request.method, request.target, request.headers, request.body.size)
    ok(block) -> exchange_h2(origin, session, submission, inbox, block)
    error(e) ->
      _ = submission.reply.send(error(e), 0)
      session
  end
end

def exchange_h2(
  origin: Origin,
  session: Optional[H2.Session],
  submission: H2.Submission,
  inbox: Channel[Order],
  block: Bytes,
) -> Optional[H2.Session]
  request = submission.request
  head_deadline = request.deadline
  held = session
  for attempt in 0..1
    connected = case held
      some(existing) -> ok(existing)
      none -> open_h2(origin, submission, inbox, head_deadline)
    end

    case connected
      error(e) ->
        _ = submission.reply.send(error(e), 0)
        return none
      ok(active) ->
        if attempt == 0
          head_deadline = [request.deadline, Time.monotonic_ms() + request.read_timeout_ms].min.unwrap!
        end

        case H2.request(active, request, block, head_deadline)
          ok(answer) ->
            _ = submission.reply.send(ok(answer.response), 0)
            return some(answer.session) if H2.reusable?(answer.session)
            close_h2(active)
            return none
          error(e) ->
            if attempt == 1 or not e.is_a?("http2.unsent")
              _ = submission.reply.send(h2_failure(e), 0)
              close_h2(active)
              return none
            end

            close_h2(active)
            held = none
        end
    end
  end

  none
end

def open_h2(origin: Origin, submission: H2.Submission, inbox: Channel[Order], deadline_ms: Int) -> Result[H2.Session]
  now = Time.monotonic_ms()
  deadline = [deadline_ms, now + submission.connect_timeout_ms].min.unwrap!
  wait = deadline - now
  kind = "http_client.timeout.connect"
  if deadline == submission.request.deadline
    kind = "http_client.timeout.request"
  elsif deadline == deadline_ms
    kind = "http_client.timeout.read"
  end

  return error("http_client: HTTP/2 connect timed out", kind: kind) if wait < 1
  opened = Dial.open_h2(
    origin.dialer,
    origin.url,
    origin.options,
    deadline,
    ->(socket, end_at) { start_h2(socket, inbox, end_at) },
  )

  case opened
    ok(_) -> opened
    error(e) -> h2_connect_failure(e, kind)
  end
end

def start_h2(socket: TCP.Socket, inbox: Channel[Order], deadline: Int) -> Result[H2.Session]
  incoming: Channel[Bytes] = Channel.new(2)
  reader = Task.spawn do read_h2(socket, incoming, inbox) end
  opened = H2.start(socket, incoming, reader, deadline)
  if not opened.ok?
    stop_reader(socket, incoming, reader)
  end

  opened
end

def h2_connect_failure(e: Error, kind: String) -> Result[H2.Session]
  return error(e) if e.is_a?("http_client")
  return error("http_client: HTTP/2 connect timed out", kind: kind, cause: e) if e.is_a?("net.timeout")

  error("http_client: HTTP/2 connect failed: #{e.message}", kind: "http_client.network", cause: e)
end

def h2_failure(e: Error) -> Result[H2.Response]
  return error(e) if e.is_a?("http_client")
  if e.is_a?("net.timeout")
    return error("http_client: HTTP/2 read timed out", kind: "http_client.timeout.read", cause: e)
  end

  if e.is_a?("hpack")
    return error("http_client: HTTP/2 header decoding failed", kind: "http_client.http2.compression", cause: e)
  end

  error("http_client: HTTP/2 exchange failed: #{e.message}", kind: "http_client.network", cause: e)
end
