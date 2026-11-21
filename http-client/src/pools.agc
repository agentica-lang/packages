## The pools of a client, one per origin, made when a request first needs one. A pool's owner task ends with the
## task that started it, so a manager task that lives as long as the client starts them all and keeps them in a map;
## a request asks it for the pool of its origin. A pool that no request wanted for `timeout_ms` and `idle_ms` has no
## request left and no connection worth keeping: the manager closes it, and the next request starts a new one.

import Dial from "dial"
import HTTP from "std/http"
import H2Origin from "http2/origin"
import Link from "link"
import Pool from "pkg/pool/pool"
import {Protocol} from "protocol"

enum OriginPool
  Http1(Pool.Pool[Link.Origin, Link.Link])
  Http2(H2Origin.Origin)
end

## The settings that every pool of the client gets, and the options its connections are opened with.
struct Settings
  size: Int
  wait_ms: Int
  idle_ms: Int
  health_ms: Int
  options: HTTP.ClientOptions
  dialer: Dial.Dialer
  protocol: Protocol = Protocol.Http1
  clock: Optional[Fn[Int]] = none
end

## The manager of the pools of a client. `stopping` closes when the client closes: the tasks of the streams read it
## between pieces, and end.
struct Pools
  inbox: Channel[Msg]
  manager: Task[Void]
  down: Channel[TaskDown]
  stopping: Channel[Bool]
end

## A request to the manager.
enum Msg
  Want(Wanted)
  Watch(Watched)
  Close(Closing)
end

## A task of a stream, and the origin whose pool it holds a connection of (empty for one that holds none).
struct Watched
  task: TaskRef
  origin: String
end

## The pool of `origin`, answered on `reply`, for a request that lasts at most `timeout_ms`.
struct Wanted
  origin: String
  timeout_ms: Int
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
  down: Channel[TaskDown] = Channel.new(1)
  Task.monitor(manager, down) do |notice| notice end
  stopping: Channel[Bool] = Channel.new(1)
  Pools(inbox: inbox, manager: manager, down: down, stopping: stopping)
end

## Has the manager wait for `task`, a task of a stream that outlives its call, when the client closes, and keep the
## pool of `origin` while the task lives. A task that starts once the client is closed is an `http_client.closed`
## error.
def watch(pools: Pools, task: TaskRef, origin: String) -> Result[Void]
  return closed() if pools.stopping.closed?

  case pools.inbox.send(Msg.Watch(Watched(task: task, origin: origin)), ASK_MS)
    error(e) if e.is_a?("channel.closed") -> closed()
    error(e) -> busy(e)
    ok(_) -> ok()
  end
end

## The pool of an origin (`scheme://host:port`), started if it is the first request to that origin in a while.
def pool_for(pools: Pools, origin: String, timeout_ms: Int) -> Result[OriginPool]
  reply: Channel[Result[OriginPool]] = Channel.new(1)
  case pools.inbox.send(Msg.Want(Wanted(origin: origin, timeout_ms: timeout_ms, reply: reply)), ASK_MS)
    error(e) if e.is_a?("channel.closed") -> return closed()
    error(e) -> return busy(e)
    ok(_) -> nil
  end

  case reply.recv(ASK_MS)
    ok(found) -> found
    error(e) if e.is_a?("channel.closed") -> closed()
    error(e) -> busy(e)
  end
end

## Closes every pool at once and ends the manager, and returns once every task of the client has ended. Closing
## twice does nothing.
def close(pools: Pools, drain_ms: Int) -> Void
  pools.stopping.close
  done: Channel[Bool] = Channel.new(1)
  if pools.inbox.send(Msg.Close(Closing(drain_ms: drain_ms, done: done)), ASK_MS).ok?
    _ = done.recv(drain_ms + CLOSE_SLACK_MS)
  end

  # The manager returns once its pools are closed; one that does not is cancelled. Either way its notice comes when
  # it is gone, and it is put back for a second close.
  case pools.down.recv(CLOSE_SLACK_MS)
    ok(notice) -> _ = pools.down.send(notice, 0)
    error(_) ->
      Task.cancel(pools.manager)
      case pools.down.recv(CLOSE_SLACK_MS)
        ok(notice) -> _ = pools.down.send(notice, 0)
        error(_) -> nil
      end
  end
end

private

INBOX_SIZE = 64
ASK_MS = 5_000
# What `Pool.close` may take after its drain: its keepers have six seconds to end their resources.
CLOSE_SLACK_MS = 8_000
# How long a cancelled stream task has to end.
CANCEL_MS = 1_000
# How often the manager looks for pools to close.
SWEEP_MS = 1_000

# The pools by origin, the tasks that close the pools the manager let go and the tasks of the streams (by task id),
# and the notices of their ends.
struct State
  pools: Map[String, Entry]
  closers: Map[Int, Task[Result[Void]]]
  streams: Map[Int, Watched]
  ended: Channel[TaskDown]
end

# A pool, and the monotonic time after which no request uses it and its connections have been idle `idle_ms`.
struct Entry
  pool: OriginPool
  until: Int
end

def closed[T]() -> Result[T] = error("http_client: the client is closed", kind: "http_client.closed")

def busy[T](cause: Error) -> Result[T]
  error("http_client: the pools did not answer within #{ASK_MS} ms", kind: "http_client.timeout.pool", cause: cause)
end

def manage(settings: Settings, inbox: Channel[Msg]) -> Void
  ended: Channel[TaskDown] = Channel.new(INBOX_SIZE)
  state = State(pools: {}, closers: {}, streams: {}, ended: ended)
  swept = now_ms(settings)
  while true
    case inbox.recv(SWEEP_MS)
      ok(Msg.Want(wanted)) -> state = state.with(pools: want(settings, state.pools, wanted, state.ended))
      ok(Msg.Watch(watched)) ->
        Task.monitor(watched.task, ended) do |notice| notice end
        state = state.with(streams: state.streams.put(watched.task.id, watched))
      ok(Msg.Close(closing)) ->
        inbox.close
        closers = state.pools.values.map { |entry| Task.spawn do shut(entry.pool, closing.drain_ms) end }
        for closer in state.closers.values + closers
          _ = Task.await(closer, closing.drain_ms + CLOSE_SLACK_MS)
        end

        streams_end(state)
        _ = closing.done.send(true, 0)
        return
      _ -> nil
    end

    now = now_ms(settings)
    if now - swept >= SWEEP_MS
      state = sweep(state, now, settings.idle_ms)
      swept = now
    end
  end
end

def now_ms(settings: Settings) -> Int
  case settings.clock
    some(clock) -> clock.call()
    none -> Time.monotonic_ms()
  end
end

# Answers the pool of the origin, started now if there is none, and gives the pools with it.
def want(settings: Settings, pools: Map[String, Entry], wanted: Wanted, ended: Channel[TaskDown]) -> Map[String, Entry]
  until = now_ms(settings) + ASK_MS + wanted.timeout_ms + settings.idle_ms
  case pools.get(wanted.origin)
    some(entry) if live?(entry.pool) ->
      _ = wanted.reply.send(ok(entry.pool), 0)
      pools.put(wanted.origin, entry.with(until: [entry.until, until].max.unwrap!))
    _ ->
      case start_pool(settings, wanted.origin)
        ok(pool) ->
          case pool
            OriginPool.Http2(origin) -> Task.monitor(origin.ref.task, ended) do |notice| notice end
            OriginPool.Http1(_) -> nil
          end

          _ = wanted.reply.send(ok(pool), 0)
          pools.put(wanted.origin, Entry(pool: pool, until: until))
        error(e) ->
          _ = wanted.reply.send(error(e), 0)
          pools
      end
  end
end

# Closes the pools past their time, each in a task of its own so that the manager does not wait, and forgets the
# closers and streams that ended. A pool with a stream alive is in use, however long ago its request came: it is kept
# `idle_ms` past now.
def sweep(state: State, now: Int, idle_ms: Int) -> State
  kept: Map[String, Entry] = {}
  swept = without_ended(state)
  closers = swept.closers
  streamed = swept.streams.values.map { |watched| watched.origin }
  for origin in swept.pools.keys
    entry = swept.pools.get(origin).unwrap!
    if entry.until > now
      kept = kept.put(origin, entry)
    elsif streamed.include?(origin)
      kept = kept.put(origin, entry.with(until: now + idle_ms))
    else
      closer = Task.spawn do shut(entry.pool, 0) end
      Task.monitor(closer, state.ended) do |notice| notice end
      closers = closers.put(closer.id, closer)
    end
  end

  swept.with(pools: kept, closers: closers)
end

# The state without the closers and streams whose end notice came. A notice means the task is gone.
def without_ended(state: State) -> State
  left = state
  notice = state.ended.recv(0)
  while notice.ok?
    id = notice.unwrap!.task_id
    left = left.with(
      closers: left.closers.delete(id),
      streams: left.streams.delete(id),
      pools: without_origin(left.pools, id),
    )

    notice = state.ended.recv(0)
  end

  left
end

def without_origin(pools: Map[String, Entry], task_id: Int) -> Map[String, Entry]
  for key in pools.keys
    case pools.get(key).unwrap!.pool
      OriginPool.Http2(origin) if origin.ref.task.id == task_id -> return pools.delete(key)
      _ -> nil
    end
  end

  pools
end

# Waits for the tasks of the streams, which end once their connection closes or at their next piece. One that does not
# end in time is cancelled.
def streams_end(state: State) -> Void
  left = without_ended(state)
  deadline = Time.monotonic_ms() + CLOSE_SLACK_MS
  while not left.streams.empty? and Time.monotonic_ms() < deadline
    case left.ended.recv([deadline - Time.monotonic_ms(), 1].max.unwrap!)
      ok(notice) -> left = left.with(streams: left.streams.delete(notice.task_id))
      error(_) -> nil
    end
  end

  for watched in left.streams.values
    Task.cancel(watched.task)
  end

  for _ in left.streams.values
    _ = left.ended.recv(CANCEL_MS)
  end
end

# Closes the pool and waits for its owner task to end: `Pool.close` cancels it without waiting.
def shut(pool: OriginPool, drain_ms: Int) -> Result[Void]
  case pool
    OriginPool.Http2(origin) -> H2Origin.close(origin, drain_ms)
    OriginPool.Http1(http1) ->
      ended: Channel[TaskDown] = Channel.new(1)
      Task.monitor(http1.owner, ended) do |notice| notice end
      Pool.close(http1, drain_ms)
      _ = ended.recv(CLOSE_SLACK_MS)
      ok()
  end
end

def live?(pool: OriginPool) -> Bool
  case pool
    OriginPool.Http2(origin) -> H2Origin.live?(origin)
    OriginPool.Http1(_) -> true
  end
end

def start_pool(settings: Settings, origin: String) -> Result[OriginPool]
  if settings.protocol == Protocol.Http2
    config = H2Origin.Config(
      origin: origin,
      dialer: settings.dialer,
      options: settings.options,
      size: settings.size,
      wait_ms: settings.wait_ms,
      idle_ms: settings.idle_ms,
    )

    return ok(OriginPool.Http2(H2Origin.start(config)))
  end

  config = Link.Origin(url: origin, options: settings.options, dialer: settings.dialer)
  pool = try Pool.start(Link.spec(config, settings.size, settings.wait_ms, settings.idle_ms, settings.health_ms))
  ok(OriginPool.Http1(pool))
end
