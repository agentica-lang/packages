## The pools of a client, one per origin, made when a request first needs one. A pool's owner task ends with the
## task that started it, so a manager task that lives as long as the client starts them all and keeps them in a map;
## a request asks it for the pool of its origin.

import Link from "link"
import Pool from "pkg/pool/pool"

type OriginPool = Pool.Pool[Link.Origin, Link.Link]

## The settings that every pool of the client gets.
struct Settings
  size: Int
  wait_ms: Int
  idle_ms: Int
  health_ms: Int
end

## The manager of the pools of a client.
struct Pools
  inbox: Channel[Msg]
  manager: Task[Void]
end

## A request to the manager.
enum Msg
  Want(Wanted)
  Close(Closing)
end

## The pool of `origin`, answered on `reply`.
struct Wanted
  origin: String
  reply: Channel[Result[OriginPool]]
end

## Close every pool, giving the requests in flight `drain_ms`, and say so on `done`.
struct Closing
  drain_ms: Int
  done: Channel[Bool]
end

## Starts the manager in a task of its own.
def start(settings: Settings) -> Pools
  inbox: Channel[Msg] = Channel.new(INBOX_SIZE)
  manager = Task.spawn do manage(settings, inbox) end
  Pools(inbox: inbox, manager: manager)
end

## The pool of an origin (`scheme://host:port`), started if it is the first request to that origin.
def pool_for(pools: Pools, origin: String) -> Result[OriginPool]
  reply: Channel[Result[OriginPool]] = Channel.new(1)
  sent = pools.inbox.send(Msg.Want(Wanted(origin: origin, reply: reply)), ASK_MS)
  return closed() if not sent.ok?

  case reply.recv(ASK_MS)
    ok(found) -> found
    error(_) -> closed()
  end
end

## Closes every pool and ends the manager. Closing twice does nothing.
def close(pools: Pools, drain_ms: Int) -> Void
  done: Channel[Bool] = Channel.new(1)
  if pools.inbox.send(Msg.Close(Closing(drain_ms: drain_ms, done: done)), ASK_MS).ok?
    _ = done.recv(drain_ms + CLOSE_SLACK_MS)
  end

  Task.cancel(pools.manager)
end

private

INBOX_SIZE = 64
ASK_MS = 5_000
# What `Pool.close` may take after its drain: its keepers have six seconds to end their resources.
CLOSE_SLACK_MS = 8_000

def closed[T]() -> Result[T] = error("http_client: the client is closed", kind: "http_client.closed")

def manage(settings: Settings, inbox: Channel[Msg]) -> Void
  pools: Map[String, OriginPool] = {}
  while true
    case inbox.recv(ASK_MS)
      ok(Msg.Want(wanted)) -> pools = want(settings, pools, wanted)
      ok(Msg.Close(closing)) ->
        for pool in pools.values
          Pool.close(pool, closing.drain_ms)
        end

        inbox.close
        _ = closing.done.send(true, 0)
        return
      _ -> nil
    end
  end
end

# Answers the pool of the origin, started now if there is none, and gives the pools with it.
def want(settings: Settings, pools: Map[String, OriginPool], wanted: Wanted) -> Map[String, OriginPool]
  case pools.get(wanted.origin)
    some(pool) ->
      _ = wanted.reply.send(ok(pool), 0)
      pools
    none ->
      case start_pool(settings, wanted.origin)
        ok(pool) ->
          _ = wanted.reply.send(ok(pool), 0)
          pools.put(wanted.origin, pool)
        error(e) ->
          _ = wanted.reply.send(error(e), 0)
          pools
      end
  end
end

def start_pool(settings: Settings, origin: String) -> Result[OriginPool]
  spec = Link.spec(Link.Origin(url: origin), settings.size, settings.wait_ms, settings.idle_ms, settings.health_ms)

  Pool.start(spec)
end
