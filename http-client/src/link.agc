## The resource of an origin's pool: a `Link`, a slot for one keep-alive connection, run by a task of its own.
##
## A handle belongs to the task that opened it, and a cancel reaches every task below the one cancelled. So no request
## opens a connection: the link task does, under the pool's keeper, under the client's manager, and the request only
## borrows it. Cancelling the task that sent a request never closes a connection that another request uses later.
##
## Making a link never connects, so the wait for a pooled connection is only the wait for a free slot; the request
## that gets an empty slot asks its link task to connect.

import HTTP from "std/http"
import Pool from "pkg/pool/pool"

## The origin of a pool, and the options (proxy, TLS) its connections are opened with.
struct Origin
  url: String
  options: HTTP.ClientOptions
end

## A connection that a request borrows, and when it expires (monotonic ms, 0 for never), from the
## `Keep-Alive: timeout=N` of the last response.
struct Held
  conn: HTTP.Connection
  expires_at: Int
end

## A link: the inbox of its task, which holds the connection, and the notice of that task's end. A link whose task
## ended (a crash) answers nothing: it fails at once, and its health check tells the pool to replace it.
struct Link
  inbox: Channel[Order]
  task: Task[Void]
  down: Channel[TaskDown]
end

## An order for the task of a link, from the request that has the link leased or from the pool's keeper.
enum Order
  Take(Channel[Optional[Held]])
  Connect(Connecting)
  Park(Held)
  Release
  Check
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

## A link of the task that serves `inbox`, watched for its end.
def watched(inbox: Channel[Order], task: Task[Void]) -> Link
  down: Channel[TaskDown] = Channel.new(1)
  Task.monitor(task, down) do |notice| notice end
  Link(inbox: inbox, task: task, down: down)
end

private

ORDER_MS = 5_000
# How long a request waits for the answer of its link task past the time of the connect itself.
ANSWER_MS = 1_000
# The link task waits for orders in long naps, until the pool ends it.
NAP_MS = 3_600_000
WATCHER_END_MS = 1_000

# A connection that waits for the next request, with the watcher task that reads its socket meanwhile: an idle
# keep-alive connection has nothing to read, so a read that ends (the server closed it, or wrote bytes out of turn)
# marks it dead, and `ended` gets the notice of the watcher.
struct Idle
  held: Held
  watcher: Task[Result[Bytes]]
  ended: Channel[TaskDown]
end

# What the link task holds: a connection that waits, and one that a request uses. At most one is there.
struct Slot
  idle: Optional[Idle]
  busy: Optional[Held]
end

def make(origin: Origin) -> Result[Link]
  inbox: Channel[Order] = Channel.new(8)
  task = Task.spawn do run(origin, inbox) end
  ok(watched(inbox, task))
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

# The notice stays in `down` once it came, for the next look.
def down?(link: Link) -> Bool
  case link.down.recv(0)
    ok(notice) ->
      _ = link.down.send(notice, 0)
      true
    error(_) -> false
  end
end

def stop(link: Link) -> Void
  link.inbox.close
  Task.cancel(link.task)
end

def run(origin: Origin, inbox: Channel[Order]) -> Void
  slot = Slot(idle: none, busy: none)
  while true
    case inbox.recv(NAP_MS)
      ok(order) -> slot = obey(origin, slot, order)
      error(e) if e.is_a?("channel.closed") ->
        drop_all(slot)
        return
      error(_) -> nil
    end
  end
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
  end
end

def open(origin: Origin, wait_ms: Int) -> Result[Held]
  conn = try HTTP.start(origin.url, origin.options.with(timeout_ms: wait_ms))
  ok(Held(conn: conn, expires_at: 0))
end

def watch(held: Held) -> Idle
  watcher = Task.spawn do TCP.recv_bytes(held.conn.socket, 1) end
  ended: Channel[TaskDown] = Channel.new(1)
  Task.monitor(watcher, ended) do |down| down end
  Idle(held: held, watcher: watcher, ended: ended)
end

# The watcher stops before the request has the socket: the link waits for the notice of its end, since a cancel that
# has not landed yet would let it read the first byte of the response. A watcher that ended on its own saw the socket
# close or bytes arrive: that connection is ended, never reused, and so is one whose watcher does not stop.
#
# A server may still close the connection just as the request is sent; the request then gets a network error, as
# with any client, and an idempotent one goes again.
def awake(idle: Optional[Idle]) -> Optional[Held]
  case idle
    some(waiting) ->
      Task.cancel(waiting.watcher)
      quiet = case waiting.ended.recv(WATCHER_END_MS)
        ok(down) -> down.reason == TaskExit.Cancelled
        error(_) -> false
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
      if waiting.ended.recv(0).ok? or expired?(waiting.held)
        Task.cancel(waiting.watcher)
        HTTP.finish(waiting.held.conn)
        return none
      end

      some(waiting)
    none -> none
  end
end

def expired?(held: Held) -> Bool = held.expires_at > 0 and Time.monotonic_ms() >= held.expires_at

def drop_all(slot: Slot) -> Void
  case slot.idle
    some(waiting) ->
      Task.cancel(waiting.watcher)
      HTTP.finish(waiting.held.conn)
    none -> nil
  end

  case slot.busy
    some(held) -> HTTP.finish(held.conn)
    none -> nil
  end
end
