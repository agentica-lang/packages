## The supervisor: one task that listens, accepts, starts a task per client and closes what ended.

import Connection from "connection"
import {ClientParts, Config, Conn, Server, ServerParts} from "types"

# How long one accept waits. It is also the longest a stop, or the close of the socket of a crashed handler, can
# take, and the pause after an accept that fails at once (EMFILE), so that error cannot spin.
ACCEPT_MS = 100
# How long `start` waits for the supervisor to listen, and `stop` for it to finish.
START_WAIT_MS = 5000
STOP_WAIT_MS = 5000
# The one accept error that is not a pause: a closed listener answers at once for ever, so the loop must end. A
# timeout is the normal quiet case and the others (no free descriptor, say) may pass.
LISTENER_CLOSED = "listener is closed"
# Each handler task ends once and makes one notice; the channel holds as many as the largest limit of sockets
# of a process, so a notice is never dropped (a full channel drops them, see Task.monitor).
DOWNS_CAPACITY = 1_048_576

struct Boot
  config: Config
  handler: Fn[Conn, Void]
  ready: Channel[Result[Int]]
  stop_signal: Channel[Bool]
end

struct Live
  socket: Socket
  task: Task[Void]
end

## Listens and returns once the port is open; `handler` runs in a task of its own for each client.
export def start(config: Config, handler: Fn[Conn, Void]) -> Result[Server]
  ready: Channel[Result[Int]] = Channel.new(1)
  stop_signal: Channel[Bool] = Channel.new(1)
  task = Task.spawn(&supervise, Boot(config: config, handler: handler, ready: ready, stop_signal: stop_signal))
  answer = try ready.recv(START_WAIT_MS)
  port = try answer
  return ok(Server(port: port, inside: ServerParts.Parts(stop_signal, task)))
end

## Stops accepting, closes every client and frees the port. It can be called again: it gives the same result.
export def stop(server: Server) -> Result[Void]
  case server.inside
    ServerParts.Parts(stop_signal, task) ->
      stop_signal.close
      case Task.await(task, STOP_WAIT_MS)
        Await.Done(result) -> return result
        Await.TimedOut ->
          Task.cancel(task)
          return error("dock: the server did not stop in #{STOP_WAIT_MS} ms")
      end
  end
end

## Waits until the server ends, with the error that ended it, if any.
export def wait(server: Server) -> Result[Void]
  case server.inside
    ServerParts.Parts(_, task) -> return Task.await(task)
  end
end

## Accepts until `stop_signal` is closed (ok) or the listener is closed under it (an error). Exported for the test.
export def accept_loop(
  listener: Listener,
  config: Config,
  handler: Fn[Conn, Void],
  stop_signal: Channel[Bool],
) -> Result[Void]
  downs: Channel[Int] = Channel.new(DOWNS_CAPACITY)
  live: Map[Int, Live] = {}
  next_id = 1
  failure = ""
  while not stop_signal.closed? and failure.empty?
    started = Time.now_ms
    case TCP.accept(listener, ACCEPT_MS)
      ok(socket) ->
        live = live.put(next_id, spawn_client(socket, next_id, config, handler, downs))
        next_id += 1
      error(message) ->
        if message.include?(LISTENER_CLOSED)
          failure = message
        else
          pause(started)
        end
    end

    live = reap(live, downs)
  end

  for entry in live.values
    Task.cancel(entry.task)
    TCP.close(entry.socket)
  end

  if failure.empty?
    return ok()
  end

  return error("dock: the listener closed: #{failure}")
end

# The listener belongs to this task, so it closes whatever way the task ends.
def supervise(boot: Boot) -> Result[Void]
  case TCP.listen(boot.config.host, boot.config.port)
    error(message) ->
      _ = boot.ready.send(error(message), 0)
      return error(message)
    ok(listener) ->
      _ = boot.ready.send(ok(TCP.local_port(listener)), 0)
      result = accept_loop(listener, boot.config, boot.handler, boot.stop_signal)
      TCP.close_listener(listener)
      return result
  end
end

def spawn_client(socket: Socket, id: Int, config: Config, handler: Fn[Conn, Void], downs: Channel[Int]) -> Live
  conn = Conn(
    id: id,
    peer: TCP.remote_address(socket),
    inside: ClientParts.Parts(socket, config.idle_ms, config.send_ms),
  )

  task = Task.spawn(&Connection.run, Connection.Link(conn: conn, handler: handler))
  Task.monitor(task, downs) do |_down| id end
  return Live(socket: socket, task: task)
end

# A timeout already waited ACCEPT_MS, so it adds no delay; an error that came sooner waits the rest.
def pause(started: Int) -> Void
  left = ACCEPT_MS - (Time.now_ms - started)
  if left > 0
    Task.sleep(left)
  end
end

# The socket is closed whether the task returned (it closed it already: a second close does nothing), crashed or was
# cancelled.
def reap(live: Map[Int, Live], downs: Channel[Int]) -> Map[Int, Live]
  left = live
  while true
    case downs.recv(0)
      error(_) -> return left
      ok(id) ->
        case left.get(id)
          none -> nil
          some(entry) -> TCP.close(entry.socket)
        end

        left = left.delete(id)
    end
  end

  return left
end
