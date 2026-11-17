## The resource of an origin's pool: a `Link`, a slot for one keep-alive connection. Making one never connects, so
## the wait for a pooled connection is only the wait for a free slot; the request that gets an empty slot connects.
##
## A handle closes with the task that owns it, and the task of a request ends with the request. So a new connection
## goes to a holder task of its own (`Task.spawn_owning`), which keeps it open until the link drops it.

import HTTP from "std/http"
import Pool from "pkg/pool/pool"

## The origin of a pool, which its links connect to.
struct Origin
  url: String
end

## A connection that a link keeps: the connection, the task that owns it, and when it expires (monotonic ms, 0 for
## never), from the `Keep-Alive: timeout=N` of the last response.
struct Held
  conn: HTTP.Connection
  holder: Task[Void]
  expires_at: Int
end

## A connection that waits in its link for the next request, with the watcher task that reads its socket meanwhile:
## an idle keep-alive connection has nothing to read, so a read that ends (the server closed it, or sent bytes out of
## turn) marks it dead, and `ended` gets the notice of the watcher.
struct Idle
  held: Held
  watcher: Task[Result[Bytes]]
  ended: Channel[TaskDown]
end

## A slot for one connection: `idle` holds it between requests, and `busy` while a request uses it, so that a request
## that is cancelled or crashes does not leave it open. Each holds one or none. Only the request that has the link
## leased (or the pool's keeper, while the link is idle) touches them.
struct Link
  idle: Channel[Idle]
  busy: Channel[Held]
end

## The `Pool.Spec` of an origin.
def spec(origin: Origin, size: Int, wait_ms: Int, idle_ms: Int, health_ms: Int) -> Pool.Spec[Origin, Link]
  Pool.Spec(
    config: origin,
    init: &make,
    checkin: &check_in,
    terminate: &drop,
    ping: &ping,
    size: size,
    checkout_ms: wait_ms,
    lease_ms: 0,
    lazy: true,
    idle_ms: idle_ms,
    health_ms: health_ms,
  )
end

## The idle connection of the link, now in use, when it is still good, else none: one that expired or that the server
## closed is ended.
def take(link: Link) -> Optional[Held]
  case link.idle.recv(0)
    ok(idle) ->
      case awake(idle)
        some(held) -> some(in_use(link, held))
        none -> none
      end

    error(_) -> none
  end
end

## Hands a new connection, opened by the caller, to a holder task, so that it outlives the caller, and puts it in use.
def hold(link: Link, conn: HTTP.Connection) -> Held
  in_use(link, Held(conn: conn, holder: Task.spawn_owning(&keep_open, conn), expires_at: 0))
end

## Puts the connection in use back in the link, for the next request, with a watcher on its socket.
def keep(link: Link, held: Held) -> Void
  _ = link.busy.recv(0)
  watcher = Task.spawn do TCP.recv_bytes(held.conn.socket, 1) end
  ended: Channel[TaskDown] = Channel.new(1)
  Task.monitor(watcher, ended) do |down| down end
  _ = link.idle.send(Idle(held: held, watcher: watcher, ended: ended), 0)
end

## Ends the connection in use: it closes, and its holder ends.
def release(link: Link, held: Held) -> Void
  _ = link.busy.recv(0)
  finish(held)
end

private

# The holder sleeps in long naps until the link cancels it.
NAP_MS = 3_600_000

def make(_origin: Origin) -> Result[Link] = ok(Link(idle: Channel.new(1), busy: Channel.new(1)))

def check_in(link: Link, outcome: Pool.Outcome) -> Result[Void]
  return ok() if outcome == Pool.Outcome.Done

  drop(link)
  error("http_client: the request did not end cleanly")
end

def drop(link: Link) -> Void
  case take(link)
    some(held) -> release(link, held)
    none -> nil
  end

  case link.busy.recv(0)
    ok(held) -> finish(held)
    error(_) -> nil
  end
end

def in_use(link: Link, held: Held) -> Held
  _ = link.busy.send(held, 0)
  held
end

def finish(held: Held) -> Void
  HTTP.finish(held.conn)
  Task.cancel(held.holder)
end

def ping(link: Link) -> Result[Void]
  case take(link)
    some(held) -> keep(link, held)
    none -> nil
  end

  ok()
end

def keep_open(_conn: HTTP.Connection) -> Void
  while true
    Task.sleep(NAP_MS)
  end
end

# The watcher stops first, so that the request has the socket alone. A watcher that ended before that saw the socket
# close or bytes arrive: that connection is ended, never reused.
def awake(idle: Idle) -> Optional[Held]
  dead = idle.ended.recv(0).ok?
  Task.cancel(idle.watcher)
  expired = idle.held.expires_at > 0 and Time.monotonic_ms() >= idle.held.expires_at
  if dead or expired
    finish(idle.held)
    return none
  end

  some(idle.held)
end
