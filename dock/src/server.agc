## The supervisor: one task that listens, accepts, starts a task per client and closes what ended.

import Connection from "connection"
import Outbox from "outbox"
import Counters from "stats"
import {ClientParts, Config, Conn, Server, ServerParts} from "types"

# How long one accept waits. It is also the longest a stop, or the close of the socket of a crashed handler, can
# take, and the pause after an accept that fails at once (EMFILE), so that error cannot spin.
ACCEPT_MS = 100
# How long `start` waits for the supervisor to listen, and `stop` for it to finish.
START_WAIT_MS = 5000
STOP_WAIT_MS = 5000
# While the grace of a stop runs, how long to wait for a client to end before looking at the clock again; and how long
# the callbacks `on_close` of the clients that a stop closed by force get, together.
DRAIN_POLL_MS = 50
CALLBACKS_MS = 1000
# The one accept error that is not a pause: a closed listener answers at once for ever, so the loop must end. A
# timeout is the normal quiet case and the others (no free descriptor, say) may pass.
LISTENER_CLOSED = "listener is closed"
# A channel holds at most this many messages. Each live connection makes one notice when its task ends, so the channel
# of the notices holds `max_connections` of them and none is dropped (a full channel drops them, see Task.monitor).
MAX_CONNECTIONS = 1_048_576
# The channel of `watch` takes the end of a few tasks.
WATCH_SLOTS = 16

export struct Boot
  config: Config
  handler: Fn[Conn, Void]
  ready: Channel[Result[Int]]
  stop_signal: Channel[Bool]
  stats: ATS[Int, Int]
  watched: Channel[String]
end

struct Live
  conn: Conn
  socket: Socket
  task: Task[Void]
end

# What the loop keeps: the clients that run, and the `on_close` tasks that run (so a stop can wait for them).
struct Table
  live: Map[Int, Live]
  hooks: List[Task[Void]]
end

# The end of a client task, as the monitor tells it.
struct Ended
  id: Int
  crashed: Bool
end

# The callback and what it gets, for the task that runs it.
struct Callback
  conn: Conn
  run: Fn[Conn, Void]
end

## Listens and returns once the port is open; `handler` runs in a task of its own for each client.
export def start(config: Config, handler: Fn[Conn, Void]) -> Result[Server]
  if config.max_outbox_bytes < Outbox.MIN_CAP or config.max_outbox_bytes > Outbox.MAX_CAP
    return error(
      "dock: max_outbox_bytes must be #{Outbox.MIN_CAP} to #{Outbox.MAX_CAP}, got #{config.max_outbox_bytes}",
    )
  end

  if config.max_connections < 1 or config.max_connections > MAX_CONNECTIONS
    return error("dock: max_connections must be 1 to #{MAX_CONNECTIONS}, got #{config.max_connections}")
  end

  if config.grace_ms < 0
    return error("dock: grace_ms must not be negative, got #{config.grace_ms}")
  end

  ready: Channel[Result[Int]] = Channel.new(1)
  stop_signal: Channel[Bool] = Channel.new(1)
  stats: ATS[Int, Int] = ATS.new()
  watched: Channel[String] = Channel.new(WATCH_SLOTS)
  boot = Boot(config: config, handler: handler, ready: ready, stop_signal: stop_signal, stats: stats, watched: watched)

  task = Task.spawn(&supervise, boot)
  answer = try ready.recv(START_WAIT_MS)
  port = try answer
  return ok(Server(port: port, inside: ServerParts.Parts(stop_signal, task, stats, watched, config.grace_ms)))
end

## `config` with `on_close` set. It takes a block, which captures what it needs (a struct field cannot hold a block
## otherwise): `Dock.on_close(config) do |conn| gone.send(conn.id, 0) end`.
export def on_close(config: Config, hook: Fn[Conn, Void]) -> Config
  return config.with(on_close: some(hook))
end

## Stops accepting, closes every client and frees the port. With a `grace_ms` the clients first get that long to have
## their queued bytes written. It can be called again: it gives the same result.
export def stop(server: Server) -> Result[Void]
  case server.inside
    ServerParts.Parts(stop_signal, task, _, _, grace_ms) ->
      stop_signal.close
      wait_ms = STOP_WAIT_MS + grace_ms + CALLBACKS_MS
      case Task.await(task, wait_ms)
        Await.Done(result) -> return result
        Await.TimedOut ->
          Task.cancel(task)
          return error("dock: the server did not stop in #{wait_ms} ms")
      end
  end
end

## Waits until the server ends, with the error that ended it, if any.
export def wait(server: Server) -> Result[Void]
  case server.inside
    ServerParts.Parts(_, task, _, _, _) -> return Task.await(task)
  end
end

## The counters now: open connections, accepted, refused, dropped and crashed. Safe from any task.
export def stats(server: Server) -> Counters.Stats
  case server.inside
    ServerParts.Parts(_, _, table, _, _) -> return Counters.snapshot(table)
  end
end

## Stops the server when `task` ends: `wait` and `stop` then return the error of a crash (ok if the task returned),
## after the same close-down as `stop`, within about 100 ms. Call it for the task that owns the state of the server;
## it can be called for more than one.
export def watch[R](server: Server, task: Task[R]) -> Void
  case server.inside
    ServerParts.Parts(_, _, _, watched, _) -> Task.monitor(task, watched) do |down| describe(down) end
  end
end

## Accepts until `stop_signal` is closed or a watched task ends (the result is ok unless that task crashed) or the
## listener is closed under it (an error). Exported for the test.
export def accept_loop(listener: Listener, boot: Boot) -> Result[Void]
  config = boot.config
  downs: Channel[Ended] = Channel.new(config.max_connections)
  table = Table(live: {}, hooks: [])
  next_id = 1
  outcome: Result[Void] = ok()
  running = true
  while running and not boot.stop_signal.closed?
    started = Time.now_ms
    case TCP.accept(listener, ACCEPT_MS)
      ok(socket) ->
        # The notices are read first, so a slot that was freed a moment ago is not refused.
        table = reap(table, downs, boot)
        if table.live.size >= config.max_connections
          TCP.close(socket)
          _ = boot.stats.add(Counters.REFUSED, 1)
        else
          table = table.with(live: table.live.put(next_id, spawn_client(socket, next_id, boot, downs)))
          next_id += 1
        end

      error(message) ->
        if message.include?(LISTENER_CLOSED)
          outcome = error("dock: the listener closed: #{message}")
          running = false
        else
          pause(started)
        end
    end

    table = reap(table, downs, boot).with(hooks: table.hooks.select do |hook| running?(hook) end)
    case boot.watched.recv(0)
      ok(reason) ->
        running = false
        if reason != "returned"
          outcome = error("dock: the watched task #{reason}")
        end

      error(_) -> nil
    end
  end

  # The port is free from here on, also during the grace.
  TCP.close_listener(listener)
  table = drain(table, downs, boot)
  for entry in table.live.values
    Task.cancel(entry.task)
    table = close_entry(table, entry, boot)
  end

  # The callbacks get a moment, so a stop does not cut one that was just started.
  deadline = Time.now_ms + CALLBACKS_MS
  for hook in table.hooks
    _ = Task.await(hook, at_least_1(deadline - Time.now_ms))
  end

  return outcome
end

# The listener belongs to this task, so it closes whatever way the task ends.
def supervise(boot: Boot) -> Result[Void]
  case TCP.listen(boot.config.host, boot.config.port)
    error(message) ->
      _ = boot.ready.send(error(message), 0)
      return error(message)
    ok(listener) ->
      _ = boot.ready.send(ok(TCP.local_port(listener)), 0)
      return accept_loop(listener, boot)
  end
end

def run_hook(callback: Callback) -> Void
  callback.run(callback.conn)
end

# An error here ends the whole server, so nothing may raise for a config that `start` accepted. The one call that
# checks its argument is Channel.new in Outbox.build, and `start` keeps its size in range. Task.spawn failing for
# lack of memory is the only other way, and `wait` and `stop` then report the crash.
def spawn_client(socket: Socket, id: Int, boot: Boot, downs: Channel[Ended]) -> Live
  config = boot.config
  outbox = Outbox.build(config.max_outbox_bytes, boot.stats)
  conn = Conn(id: id, peer: TCP.remote_address(socket), inside: ClientParts.Parts(socket, config.idle_ms, outbox))
  task = Task.spawn(&Connection.run, Connection.Link(conn: conn, handler: boot.handler))
  Task.monitor(task, downs) do |down| Ended(id: id, crashed: down.reason == TaskExit.Crashed) end
  _ = boot.stats.add(Counters.OPEN, 1)
  _ = boot.stats.add(Counters.ACCEPTED, 1)
  return Live(conn: conn, socket: socket, task: task)
end

# A timeout already waited ACCEPT_MS, so it adds no delay; an error that came sooner waits the rest.
def pause(started: Int) -> Void
  left = ACCEPT_MS - (Time.now_ms - started)
  if left > 0
    Task.sleep(left)
  end
end

def at_least_1(ms: Int) -> Int
  if ms < 1
    return 1
  end

  return ms
end

def describe(down: TaskDown) -> String
  case down.reason
    TaskExit.Ok -> return "returned"
    TaskExit.Cancelled -> return "was cancelled"
    TaskExit.Crashed -> return "crashed: #{down.code} #{down.message}"
  end
end

# The socket is closed whether the task returned (it closed it already: a second close does nothing), crashed or was
# cancelled.
def reap(table: Table, downs: Channel[Ended], boot: Boot) -> Table
  left = table
  while true
    case downs.recv(0)
      error(_) -> return left
      ok(ended) -> left = settle(left, ended, boot)
    end
  end

  return left
end

def settle(table: Table, ended: Ended, boot: Boot) -> Table
  case table.live.get(ended.id)
    none -> return table
    some(entry) ->
      if ended.crashed
        _ = boot.stats.add(Counters.CRASHED, 1)
      end

      return close_entry(table, entry, boot).with(live: table.live.delete(ended.id))
  end
end

# Closes the socket, counts the end and starts `on_close`, which nobody waits for.
def close_entry(table: Table, entry: Live, boot: Boot) -> Table
  TCP.close(entry.socket)
  _ = boot.stats.add(Counters.OPEN, -1)
  case boot.config.on_close
    none -> return table
    some(hook) ->
      return table.with(hooks: table.hooks.push(Task.spawn(&run_hook, Callback(conn: entry.conn, run: hook))))
  end
end

def running?(task: Task[Void]) -> Bool
  case Task.await(task, 1)
    Await.TimedOut -> return true
    Await.Done(_) -> return false
  end
end

# The stop with a grace: every client is closed as `Dock.close` does (what is queued is written, then the socket
# closes, which ends a handler that is reading), and the loop waits for the tasks until the grace is over.
def drain(table: Table, downs: Channel[Ended], boot: Boot) -> Table
  left = table
  deadline = Time.now_ms + boot.config.grace_ms
  if boot.config.grace_ms <= 0
    return left
  end

  for entry in table.live.values
    Connection.close(entry.conn)
  end

  while not left.live.empty? and Time.now_ms < deadline
    case downs.recv(DRAIN_POLL_MS)
      ok(ended) -> left = settle(left, ended, boot)
      error(_) -> nil
    end
  end

  return left
end
